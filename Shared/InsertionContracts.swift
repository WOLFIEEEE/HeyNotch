import Foundation

struct InsertionTarget: Codable, Equatable, Sendable {
    let token: UUID
    let processID: Int32
    let bundleIdentifier: String
    let applicationName: String
}

struct CaptureInsertionRequest: Codable, Sendable {
    let operationID: UUID
    let processID: Int32
    let bundleIdentifier: String
    var validitySeconds: TimeInterval = 60
}

struct TextInsertionRequest: Codable, Sendable {
    let operationID: UUID
    let target: InsertionTarget
    let text: String
    let restoreClipboard: Bool
    var expiresAt: Date = Date().addingTimeInterval(10)
}

enum InsertionStatus: String, Codable, Error, Sendable {
    case targetReady, pasteSent, accessibilityRequired, secureInput, unsupportedField
    case targetChanged, targetExpired, invalidRequest, busy, cancelled, modifiersHeld
    case clipboardUnavailable, clipboardChanged, eventUnavailable, helperUnavailable, outcomeUnknown

    var message: String {
        switch self {
        case .targetReady: return "Ready to paste."
        case .pasteSent: return "Paste sent. Check the destination app."
        case .accessibilityRequired: return "Allow HeyNotch in System Settings → Privacy & Security → Accessibility, then try again."
        case .secureInput: return "Text insertion is unavailable in a protected field or while secure keyboard input is active."
        case .unsupportedField: return "Click an editable text field, then use the shortcut again."
        case .targetChanged: return "The app, field, or selection changed. Your text is still available to copy."
        case .targetExpired: return "The destination expired. Focus the field and start a new attempt."
        case .invalidRequest: return "This insertion request is no longer valid. Start a new attempt."
        case .busy: return "An insertion is already in progress."
        case .cancelled: return "Insertion cancelled. Your text is still available to copy."
        case .modifiersHeld: return "Release the shortcut keys and try again."
        case .clipboardUnavailable: return "The clipboard could not be preserved. Copy the text, or turn off clipboard restoration before trying again."
        case .clipboardChanged: return "The clipboard changed during preparation. Nothing was pasted."
        case .eventUnavailable: return "macOS could not prepare the paste shortcut. Your text is still available to copy."
        case .helperUnavailable: return "The text insertion helper is unavailable. Use a signed HeyNotch build and try again."
        case .outcomeUnknown: return "The helper stopped responding. Check the destination before trying again; the paste may have been sent."
        }
    }
}

enum ClipboardDisposition: String, Codable, Sendable {
    case untouched, restored, keptText, newerCopyPreserved, restorationFailed
}

struct InsertionResponse: Codable, Sendable {
    let operationID: UUID
    let status: InsertionStatus
    var target: InsertionTarget? = nil
    var clipboard: ClipboardDisposition = .untouched
}

/// Only eagerly available bytes are retained, in memory, for the duration of a paste.
struct InsertionClipboardSnapshot: Equatable {
    let changeCount: Int
    let items: [[String: Data]]
}

struct InsertionClipboardLease: Equatable {
    let changeCount: Int
    let marker: String
}

@MainActor
protocol InsertionEnvironment: AnyObject {
    var now: Date { get }
    var clipboardChangeCount: Int { get }
    var modifiersAreReleased: Bool { get }
    func capture(_ request: CaptureInsertionRequest) -> Result<InsertionTarget, InsertionStatus>
    func validate(_ target: InsertionTarget) -> InsertionStatus?
    func preparePaste() -> Bool
    func snapshotClipboard() -> InsertionClipboardSnapshot?
    func writeClipboard(_ text: String, operationID: UUID, expectedChangeCount: Int,
                        rollbackSnapshot: InsertionClipboardSnapshot?) -> InsertionClipboardLease?
    func ownsClipboard(_ lease: InsertionClipboardLease) -> Bool
    func restoreClipboard(_ snapshot: InsertionClipboardSnapshot, lease: InsertionClipboardLease) -> Bool
    func postPaste(to target: InsertionTarget)
    func wait(milliseconds: Int) async
}
