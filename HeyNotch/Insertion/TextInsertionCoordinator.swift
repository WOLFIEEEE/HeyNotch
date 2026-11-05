import AppKit
import Combine

@MainActor
final class TextInsertionCoordinator: ObservableObject {
    static let shared = TextInsertionCoordinator()
    static let enabledKey = "textInsertionPreviewEnabled"
    static let restoreKey = "textInsertionRestoreClipboard"

    @Published var sampleText = "Hello from HeyNotch. Text insertion is working."
    @Published private(set) var retainedText = ""
    @Published private(set) var status = "Focus a text field in another app, then use the insertion shortcut."
    @Published private(set) var isBusy = false
    @Published private(set) var needsAccessibility = false
    @Published private(set) var destination = ""

    private let client = TextInsertionClient()
    private var operationID: UUID?
    private var cancelled = false
    private var countdown: Task<Void, Never>?
    private var statusPanel: InsertionStatusPanel?

    func insertSample() {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey), !isBusy else { return }
        guard !sampleText.isEmpty, sampleText.utf8.count <= 65_536 else {
            status = "Enter between 1 and 65,536 bytes of text to try insertion."
            showStatus()
            return
        }
        retainedText = sampleText
        needsAccessibility = false
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = app.bundleIdentifier else {
            status = "macOS could not identify the destination app. Focus a text field and try again."
            showStatus()
            return
        }
        guard bundleIdentifier != Bundle.main.bundleIdentifier else {
            status = "HeyNotch is still the active app. Switch to your text editor, then use the insertion shortcut."
            showStatus()
            return
        }
        let id = UUID()
        operationID = id
        cancelled = false
        isBusy = true
        destination = app.localizedName ?? bundleIdentifier
        status = "Preparing text for \(destination)…"
        showStatus()
        let capture = CaptureInsertionRequest(operationID: id, processID: app.processIdentifier,
                                              bundleIdentifier: bundleIdentifier)
        let text = retainedText
        let restore = UserDefaults.standard.object(forKey: Self.restoreKey) as? Bool ?? true
        Task {
            let captured = await client.capture(capture)
            guard operationID == id else { return }
            guard !cancelled else { complete(InsertionResponse(operationID: id, status: .cancelled)); return }
            guard captured.status == .targetReady, let target = captured.target else { complete(captured); return }
            status = "Pasting into \(destination)…"
            let result = await client.insert(TextInsertionRequest(operationID: id, target: target,
                                                                  text: text, restoreClipboard: restore))
            guard operationID == id else { return }
            complete(result)
        }
    }

    func tryAfterCountdown() {
        guard !isBusy else { return }
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        isBusy = true
        needsAccessibility = false
        destination = ""
        showStatus()
        countdown = Task {
            for seconds in stride(from: 5, through: 1, by: -1) {
                status = "Click a text field in another app. Trying in \(seconds)…"
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            isBusy = false
            countdown = nil
            insertSample()
        }
    }

    func cancel() {
        if let countdown {
            countdown.cancel()
            self.countdown = nil
            isBusy = false
            status = InsertionStatus.cancelled.message
            return
        }
        guard let operationID else { return }
        cancelled = true
        client.cancel(operationID)
        status = "Cancelling… If paste was already sent, check the destination."
    }

    func requestAccessibility() {
        XPCHelperClient.shared.requestAccessibilityAuthorization()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func copyRetainedText() {
        guard !retainedText.isEmpty, !isBusy else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        status = pasteboard.setString(retainedText, forType: .string)
            ? "Text copied. Paste it where you want it."
            : "The clipboard could not be updated. Your text is still available here."
    }

    func dismissStatus() { statusPanel?.orderOut(nil) }

    private func complete(_ result: InsertionResponse) {
        isBusy = false
        operationID = nil
        needsAccessibility = result.status == .accessibilityRequired
        status = "\(destination): \(result.status.message)"
        if result.status == .pasteSent {
            switch result.clipboard {
            case .restored: status += " Your clipboard was restored."
            case .newerCopyPreserved: status += " Your newer clipboard content was kept."
            case .keptText: status += " The inserted text remains on the clipboard."
            case .restorationFailed: status += " The clipboard could not be restored."
            case .untouched: break
            }
        }
    }

    private func showStatus() {
        if statusPanel == nil { statusPanel = InsertionStatusPanel(coordinator: self) }
        statusPanel?.showWithoutActivation()
    }
}
