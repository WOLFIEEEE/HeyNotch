import AppKit
import ApplicationServices
import Carbon

@MainActor
final class SystemInsertionEnvironment: InsertionEnvironment {
    private struct Focus {
        let target: InsertionTarget
        let element: AXUIElement
        let window: AXUIElement?
        let selection: CFRange?
        let launchDate: Date?
    }
    private var focus: Focus?
    private var events: (CGEvent, CGEvent)?
    private let pasteboard: NSPasteboard
    private let markerType = NSPasteboard.PasteboardType("com.wolfieeee.heynotch.insertion-operation")

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    var now: Date { Date() }
    var clipboardChangeCount: Int { pasteboard.changeCount }
    var modifiersAreReleased: Bool {
        CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
    }

    func capture(_ request: CaptureInsertionRequest) -> Result<InsertionTarget, InsertionStatus> {
        focus = nil
        if let failure = permissionFailure() { return .failure(failure) }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == request.processID,
              app.bundleIdentifier == request.bundleIdentifier,
              app.bundleIdentifier != XPCPeerTrust.appIdentifier else { return .failure(.targetChanged) }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        guard let element = elementAttribute(application, kAXFocusedUIElementAttribute) else { return .failure(.unsupportedField) }
        AXUIElementSetMessagingTimeout(element, 0.5)
        if let failure = fieldFailure(element) { return .failure(failure) }
        let target = InsertionTarget(token: UUID(), processID: app.processIdentifier,
                                     bundleIdentifier: request.bundleIdentifier,
                                     applicationName: app.localizedName ?? request.bundleIdentifier)
        focus = Focus(target: target, element: element,
                      window: elementAttribute(application, kAXFocusedWindowAttribute),
                      selection: selection(element), launchDate: app.launchDate)
        return .success(target)
    }

    func validate(_ target: InsertionTarget) -> InsertionStatus? {
        if let failure = permissionFailure() { return failure }
        guard let focus, focus.target == target,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == target.processID, app.bundleIdentifier == target.bundleIdentifier,
              app.launchDate == focus.launchDate, !app.isTerminated else { return .targetChanged }
        let application = AXUIElementCreateApplication(target.processID)
        AXUIElementSetMessagingTimeout(application, 0.5)
        guard let current = elementAttribute(application, kAXFocusedUIElementAttribute),
              CFEqual(current, focus.element) else { return .targetChanged }
        if let window = focus.window {
            guard let currentWindow = elementAttribute(application, kAXFocusedWindowAttribute),
                  CFEqual(window, currentWindow) else { return .targetChanged }
        }
        if let original = focus.selection {
            guard let currentSelection = selection(current), original.location == currentSelection.location,
                  original.length == currentSelection.length else { return .targetChanged }
        }
        return fieldFailure(current)
    }

    private func permissionFailure() -> InsertionStatus? {
        guard AXIsProcessTrusted() else { return .accessibilityRequired }
        guard !IsSecureEventInputEnabled() else { return .secureInput }
        return nil
    }

    private func fieldFailure(_ element: AXUIElement) -> InsertionStatus? {
        let role = attribute(element, kAXRoleAttribute) as? String
        let subrole = attribute(element, kAXSubroleAttribute) as? String
        if subrole == kAXSecureTextFieldSubrole || (attribute(element, "AXProtectedContent") as? Bool) == true {
            return .secureInput
        }
        guard let role, [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              (attribute(element, kAXEnabledAttribute) as? Bool) != false else { return .unsupportedField }
        // Standard fields expose settable value or an editable flag. Some editors
        // expose only a settable selection, so preserve support for those editors.
        var valueSettable = DarwinBoolean(false)
        var selectionSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &selectionSettable)
        if (attribute(element, "AXEditable") as? Bool) == false { return .unsupportedField }
        guard valueSettable.boolValue || selectionSettable.boolValue || (attribute(element, "AXEditable") as? Bool) == true else {
            return .unsupportedField
        }
        return nil
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func selection(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }

    func preparePaste() -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        up.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        events = (down, up)
        return true
    }

    func snapshotClipboard() -> InsertionClipboardSnapshot? {
        let generation = pasteboard.changeCount
        let original = pasteboard.pasteboardItems ?? []
        guard !original.isEmpty || (pasteboard.types?.isEmpty ?? true) else { return nil }
        guard original.count <= 64 else { return nil }
        var items: [[String: Data]] = []
        var byteCount = 0
        for item in original {
            guard !item.types.isEmpty, item.types.count <= 64 else { return nil }
            var formats: [String: Data] = [:]
            for type in item.types {
                // Promises cannot be faithfully recreated from an eager byte snapshot.
                guard !type.rawValue.lowercased().contains("promise"), let data = item.data(forType: type) else { return nil }
                byteCount += data.count
                guard byteCount <= 16 * 1024 * 1024 else { return nil }
                formats[type.rawValue] = data
            }
            items.append(formats)
        }
        guard generation == pasteboard.changeCount else { return nil }
        return InsertionClipboardSnapshot(changeCount: generation, items: items)
    }

    func writeClipboard(_ text: String, operationID: UUID, expectedChangeCount: Int,
                        rollbackSnapshot: InsertionClipboardSnapshot? = nil) -> InsertionClipboardLease? {
        guard pasteboard.changeCount == expectedChangeCount else { return nil }
        let item = NSPasteboardItem()
        let marker = operationID.uuidString
        guard item.setString(text, forType: .string), item.setString(marker, forType: markerType) else { return nil }
        let generation = pasteboard.clearContents()
        guard pasteboard.changeCount == generation else { return nil }
        guard pasteboard.writeObjects([item]) else {
            if let rollbackSnapshot, pasteboard.changeCount == generation {
                _ = replaceClipboard(rollbackSnapshot, expectedChangeCount: generation)
            }
            return nil
        }
        let lease = InsertionClipboardLease(changeCount: generation, marker: marker)
        return ownsClipboard(lease) ? lease : nil
    }

    func ownsClipboard(_ lease: InsertionClipboardLease) -> Bool {
        pasteboard.changeCount == lease.changeCount && pasteboard.string(forType: markerType) == lease.marker
    }

    func restoreClipboard(_ snapshot: InsertionClipboardSnapshot, lease: InsertionClipboardLease) -> Bool {
        guard ownsClipboard(lease) else { return false }
        return replaceClipboard(snapshot, expectedChangeCount: lease.changeCount)
    }

    private func replaceClipboard(_ snapshot: InsertionClipboardSnapshot, expectedChangeCount: Int) -> Bool {
        let items = snapshot.items.map { formats in
            let item = NSPasteboardItem()
            for (type, data) in formats { item.setData(data, forType: .init(type)) }
            return item
        }
        guard pasteboard.changeCount == expectedChangeCount else { return false }
        let generation = pasteboard.clearContents()
        guard pasteboard.changeCount == generation else { return false }
        return items.isEmpty || pasteboard.writeObjects(items)
    }

    func postPaste(to target: InsertionTarget) {
        // Target this process rather than posting into whichever app happens to be frontmost.
        events?.0.postToPid(target.processID)
        events?.1.postToPid(target.processID)
        events = nil
    }

    func wait(milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
}
