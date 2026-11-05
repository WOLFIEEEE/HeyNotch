import Foundation
import XCTest

@MainActor
final class TextInsertionEngineTests: XCTestCase {
    private func session(_ environment: FakeInsertionEnvironment) -> (TextInsertionEngine, TextInsertionRequest) {
        let engine = TextInsertionEngine(environment: environment)
        let id = UUID()
        let captured = engine.capture(CaptureInsertionRequest(operationID: id, processID: 42, bundleIdentifier: "test.editor"))
        return (engine, TextInsertionRequest(operationID: id, target: captured.target!, text: "Hello, 世界 👋\nSecond line.",
                                             restoreClipboard: true, expiresAt: environment.now.addingTimeInterval(10)))
    }

    func testPastePreservesUnicodeAndMultipleLinesAndRestoresEveryFormat() async {
        let environment = FakeInsertionEnvironment()
        let original = environment.items
        let (engine, request) = session(environment)
        let result = await engine.insert(request)
        XCTAssertEqual(result.status, .pasteSent)
        XCTAssertEqual(result.clipboard, .restored)
        XCTAssertEqual(environment.pastedTexts, [request.text])
        XCTAssertEqual(environment.items, original)
        XCTAssertEqual(environment.calls, ["validate", "prepare", "snapshot", "validate", "write", "validate", "paste", "wait:1000", "restore"])
    }

    func testPermissionAndSecureFieldFailuresDoNotTouchClipboard() async {
        for failure in [InsertionStatus.accessibilityRequired, .secureInput, .unsupportedField, .targetChanged] {
            let environment = FakeInsertionEnvironment()
            let (engine, request) = session(environment)
            let original = environment.items
            environment.validationFailure = failure
            let result = await engine.insert(request)
            XCTAssertEqual(result.status, failure)
            XCTAssertEqual(environment.items, original)
            XCTAssertTrue(environment.pastedTexts.isEmpty)
            XCTAssertFalse(environment.calls.contains("write"))
        }
    }

    func testCaptureFailureReturnsNoTarget() {
        let environment = FakeInsertionEnvironment()
        environment.captureFailure = .accessibilityRequired
        let engine = TextInsertionEngine(environment: environment)
        let result = engine.capture(CaptureInsertionRequest(operationID: UUID(), processID: 42, bundleIdentifier: "test.editor"))
        XCTAssertEqual(result.status, .accessibilityRequired)
        XCTAssertNil(result.target)
    }

    func testClipboardCopyDuringPasteIsNeverReplacedByOldSnapshot() async {
        let environment = FakeInsertionEnvironment()
        let (engine, request) = session(environment)
        environment.onWait = { _ in environment.userCopy("newer copy") }
        let result = await engine.insert(request)
        XCTAssertEqual(result.status, .pasteSent)
        XCTAssertEqual(result.clipboard, .newerCopyPreserved)
        XCTAssertEqual(environment.string, "newer copy")
        XCTAssertFalse(environment.calls.contains("restore"))
    }

    func testCopyDuringSnapshotAbortsBeforeWriting() async {
        let environment = FakeInsertionEnvironment()
        let (engine, request) = session(environment)
        environment.afterSnapshot = { environment.userCopy("new copy") }
        let result = await engine.insert(request)
        XCTAssertEqual(result.status, .clipboardChanged)
        XCTAssertEqual(environment.string, "new copy")
        XCTAssertTrue(environment.pastedTexts.isEmpty)
        XCTAssertFalse(environment.calls.contains("write"))
    }

    func testFocusChangeAfterWritingRestoresClipboardWithoutPasting() async {
        let environment = FakeInsertionEnvironment()
        let original = environment.items
        let (engine, request) = session(environment)
        environment.afterWrite = { environment.validationFailure = .targetChanged }
        let result = await engine.insert(request)
        XCTAssertEqual(result.status, .targetChanged)
        XCTAssertEqual(result.clipboard, .restored)
        XCTAssertEqual(environment.items, original)
        XCTAssertTrue(environment.pastedTexts.isEmpty)
    }

    func testLostClipboardOwnershipBeforePasteDoesNotPasteNewerCopy() async {
        let environment = FakeInsertionEnvironment()
        let (engine, request) = session(environment)
        environment.afterWrite = { environment.userCopy("new copy") }
        let result = await engine.insert(request)
        XCTAssertEqual(result.status, .clipboardChanged)
        XCTAssertEqual(result.clipboard, .newerCopyPreserved)
        XCTAssertEqual(environment.string, "new copy")
        XCTAssertTrue(environment.pastedTexts.isEmpty)
    }

    func testDuplicateRequestDoesNotPasteTwice() async {
        let environment = FakeInsertionEnvironment()
        let (engine, request) = session(environment)
        _ = await engine.insert(request)
        let result = await engine.insert(request)
        XCTAssertEqual(result.status, .pasteSent)
        XCTAssertEqual(environment.pastedTexts.count, 1)
    }

    func testConsumedTargetCannotBeReusedWithNewOperationID() async {
        let environment = FakeInsertionEnvironment()
        let (engine, request) = session(environment)
        _ = await engine.insert(request)
        let replay = TextInsertionRequest(operationID: UUID(), target: request.target, text: "replay", restoreClipboard: true)
        let result = await engine.insert(replay)
        XCTAssertEqual(result.status, .invalidRequest)
        XCTAssertEqual(environment.pastedTexts.count, 1)
    }

    func testCancellationWhileWaitingForModifiersDoesNotPaste() async {
        let environment = FakeInsertionEnvironment()
        let (engine, request) = session(environment)
        environment.modifiersAreReleased = false
        environment.onWait = { _ in engine.cancel(request.operationID) }
        let result = await engine.insert(request)
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertTrue(environment.pastedTexts.isEmpty)
        XCTAssertFalse(environment.calls.contains("write"))
    }

    func testCancellationAfterPostingStillRestoresAndReportsPasteSent() async {
        let environment = FakeInsertionEnvironment()
        let original = environment.items
        let (engine, request) = session(environment)
        environment.onWait = { _ in engine.cancel(request.operationID) }
        let result = await engine.insert(request)
        XCTAssertEqual(result.status, .pasteSent)
        XCTAssertEqual(result.clipboard, .restored)
        XCTAssertEqual(environment.items, original)
    }

    func testHelperConnectionEndingDiscardsPreparedTarget() async {
        let environment = FakeInsertionEnvironment()
        let (engine, request) = session(environment)
        engine.connectionEnded()
        let result = await engine.insert(request)
        XCTAssertEqual(result.status, .invalidRequest)
        XCTAssertTrue(environment.pastedTexts.isEmpty)
    }

    func testExpiredRequestNeverWritesClipboard() async {
        let environment = FakeInsertionEnvironment()
        let (engine, request) = session(environment)
        environment.now = environment.now.addingTimeInterval(11)
        let result = await engine.insert(request)
        XCTAssertEqual(result.status, .targetExpired)
        XCTAssertFalse(environment.calls.contains("write"))
    }

    func testDeadlinePassingDuringClipboardWorkPreventsPaste() async {
        let environment = FakeInsertionEnvironment()
        let (engine, request) = session(environment)
        environment.afterWrite = { environment.now = environment.now.addingTimeInterval(11) }
        let result = await engine.insert(request)
        XCTAssertNotEqual(result.status, .pasteSent)
        XCTAssertEqual(result.clipboard, .restored)
        XCTAssertTrue(environment.pastedTexts.isEmpty)
    }

    func testUnreleasedShortcutModifiersPreventPaste() async {
        let environment = FakeInsertionEnvironment()
        let (engine, request) = session(environment)
        environment.modifiersAreReleased = false
        let result = await engine.insert(request)
        XCTAssertEqual(result.status, .modifiersHeld)
        XCTAssertTrue(environment.pastedTexts.isEmpty)
    }

    func testUnavailableSnapshotDoesNotOverwriteClipboard() async {
        let environment = FakeInsertionEnvironment()
        let original = environment.items
        let (engine, request) = session(environment)
        environment.snapshotAvailable = false
        let result = await engine.insert(request)
        XCTAssertEqual(result.status, .clipboardUnavailable)
        XCTAssertEqual(environment.items, original)
    }

    func testRestorationCanBeDisabledWithoutReadingOldClipboard() async {
        let environment = FakeInsertionEnvironment()
        let (engine, initial) = session(environment)
        let request = TextInsertionRequest(operationID: initial.operationID, target: initial.target,
                                            text: initial.text, restoreClipboard: false)
        environment.snapshotAvailable = false
        let result = await engine.insert(request)
        XCTAssertEqual(result.status, .pasteSent)
        XCTAssertEqual(result.clipboard, .keptText)
        XCTAssertEqual(environment.string, request.text)
        XCTAssertFalse(environment.calls.contains("snapshot"))
    }

    func testUnableToPrepareEventsDoesNotOverwriteClipboard() async {
        let environment = FakeInsertionEnvironment()
        let (engine, request) = session(environment)
        environment.eventsAvailable = false
        let result = await engine.insert(request)
        XCTAssertEqual(result.status, .eventUnavailable)
        XCTAssertFalse(environment.calls.contains("write"))
    }

    func testRestorationFailureIsReportedWithoutRepeatingPaste() async {
        let environment = FakeInsertionEnvironment()
        let (engine, request) = session(environment)
        environment.restorationSucceeds = false
        let result = await engine.insert(request)
        XCTAssertEqual(result.status, .pasteSent)
        XCTAssertEqual(result.clipboard, .restorationFailed)
        XCTAssertEqual(environment.pastedTexts.count, 1)
    }
}

@MainActor
private final class FakeInsertionEnvironment: InsertionEnvironment {
    var now = Date()
    var clipboardChangeCount = 1
    var modifiersAreReleased = true
    var captureFailure: InsertionStatus?
    var validationFailure: InsertionStatus?
    var eventsAvailable = true
    var snapshotAvailable = true
    var restorationSucceeds = true
    var calls: [String] = []
    var pastedTexts: [String] = []
    var items: [[String: Data]] = [["public.utf8-plain-text": Data("original".utf8),
                                   "public.rtf": Data("{\\rtf1 original}".utf8)],
                                  ["public.png": Data([137, 80, 78, 71])]]
    var marker = ""
    var afterWrite: (() -> Void)?
    var afterSnapshot: (() -> Void)?
    var onWait: ((Int) -> Void)?
    var string: String? { items.first?["public.utf8-plain-text"].flatMap { String(data: $0, encoding: .utf8) } }

    func capture(_ request: CaptureInsertionRequest) -> Result<InsertionTarget, InsertionStatus> {
        if let captureFailure { return .failure(captureFailure) }
        return .success(InsertionTarget(token: UUID(), processID: request.processID,
                                        bundleIdentifier: request.bundleIdentifier, applicationName: "Test editor"))
    }
    func validate(_ target: InsertionTarget) -> InsertionStatus? { calls.append("validate"); return validationFailure }
    func preparePaste() -> Bool { calls.append("prepare"); return eventsAvailable }
    func snapshotClipboard() -> InsertionClipboardSnapshot? {
        calls.append("snapshot")
        let snapshot = InsertionClipboardSnapshot(changeCount: clipboardChangeCount, items: items)
        afterSnapshot?()
        return snapshotAvailable ? snapshot : nil
    }
    func writeClipboard(_ text: String, operationID: UUID, expectedChangeCount: Int,
                        rollbackSnapshot: InsertionClipboardSnapshot? = nil) -> InsertionClipboardLease? {
        calls.append("write")
        guard clipboardChangeCount == expectedChangeCount else { return nil }
        userCopy(text)
        marker = operationID.uuidString
        let lease = InsertionClipboardLease(changeCount: clipboardChangeCount, marker: marker)
        afterWrite?()
        return lease
    }
    func ownsClipboard(_ lease: InsertionClipboardLease) -> Bool { lease.changeCount == clipboardChangeCount && lease.marker == marker }
    func restoreClipboard(_ snapshot: InsertionClipboardSnapshot, lease: InsertionClipboardLease) -> Bool {
        calls.append("restore")
        guard restorationSucceeds, ownsClipboard(lease) else { return false }
        items = snapshot.items
        clipboardChangeCount += 1
        return true
    }
    func postPaste(to target: InsertionTarget) { calls.append("paste"); pastedTexts.append(string ?? "") }
    func wait(milliseconds: Int) async { calls.append("wait:\(milliseconds)"); onWait?(milliseconds) }
    func userCopy(_ text: String) { items = [["public.utf8-plain-text": Data(text.utf8)]]; marker = ""; clipboardChangeCount += 1 }
}
