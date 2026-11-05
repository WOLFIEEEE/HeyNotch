import Foundation

/// A single serialized insertion session. Dependencies are injectable so failures
/// can be exercised without sending real keystrokes or reading the user's clipboard.
@MainActor
final class TextInsertionEngine {
    private let environment: InsertionEnvironment
    private var prepared: (operationID: UUID, target: InsertionTarget, expires: Date)?
    private var inFlight: UUID?
    private var cancelled: Set<UUID> = []
    private var completed: [UUID: InsertionResponse] = [:]
    private var completionOrder: [UUID] = []

    init(environment: InsertionEnvironment) { self.environment = environment }

    func capture(_ request: CaptureInsertionRequest) -> InsertionResponse {
        guard inFlight == nil else { return response(request.operationID, .busy) }
        guard !cancelled.contains(request.operationID) else { return response(request.operationID, .cancelled) }
        guard completed[request.operationID] == nil,
              request.processID > 0, !request.bundleIdentifier.isEmpty else {
            return response(request.operationID, .invalidRequest)
        }
        prepared = nil
        switch environment.capture(request) {
        case .success(let target):
            let lifetime = request.validitySeconds.isFinite ? min(300, max(1, request.validitySeconds)) : 60
            prepared = (request.operationID, target, environment.now.addingTimeInterval(lifetime))
            return InsertionResponse(operationID: request.operationID, status: .targetReady, target: target)
        case .failure(let status):
            return response(request.operationID, status)
        }
    }

    func cancel(_ operationID: UUID) {
        // Only one prepared/in-flight operation exists. Bound pre-request cancellation tombstones.
        if cancelled.count >= 128 { cancelled = inFlight.map { [$0] } ?? [] }
        cancelled.insert(operationID)
        if prepared?.operationID == operationID { prepared = nil }
    }

    func connectionEnded() {
        if let operationID = inFlight { cancel(operationID) }
        prepared = nil
    }

    func insert(_ request: TextInsertionRequest) async -> InsertionResponse {
        if let previous = completed[request.operationID] { return previous }
        guard inFlight == nil else { return response(request.operationID, .busy) }
        guard !cancelled.contains(request.operationID) else { return finish(request.operationID, .cancelled) }
        guard !request.text.isEmpty, request.text.utf8.count <= 65_536,
              let captured = prepared, captured.operationID == request.operationID,
              captured.target == request.target else {
            return finish(request.operationID, .invalidRequest)
        }
        prepared = nil // A token can be consumed only once, even if this attempt fails.
        inFlight = request.operationID
        defer { inFlight = nil }

        for _ in 0..<100 {
            if environment.modifiersAreReleased { break }
            if cancelled.contains(request.operationID) { return finish(request.operationID, .cancelled) }
            await environment.wait(milliseconds: 10)
        }
        guard !cancelled.contains(request.operationID) else { return finish(request.operationID, .cancelled) }
        guard environment.now < min(captured.expires, request.expiresAt) else { return finish(request.operationID, .targetExpired) }
        guard environment.modifiersAreReleased else { return finish(request.operationID, .modifiersHeld) }
        if let failure = environment.validate(request.target) { return finish(request.operationID, failure) }
        guard environment.preparePaste() else { return finish(request.operationID, .eventUnavailable) }

        let originalCount = environment.clipboardChangeCount
        let snapshot = request.restoreClipboard ? environment.snapshotClipboard() : nil
        if request.restoreClipboard && snapshot == nil { return finish(request.operationID, .clipboardUnavailable) }
        guard environment.clipboardChangeCount == originalCount,
              snapshot == nil || snapshot?.changeCount == originalCount else {
            return finish(request.operationID, .clipboardChanged)
        }
        // Reading rich clipboard data may take time. Check the field again afterwards.
        if let failure = environment.validate(request.target) { return finish(request.operationID, failure) }
        guard !cancelled.contains(request.operationID) else { return finish(request.operationID, .cancelled) }
        guard environment.now < min(captured.expires, request.expiresAt) else { return finish(request.operationID, .targetExpired) }
        guard let lease = environment.writeClipboard(request.text, operationID: request.operationID,
                                                       expectedChangeCount: originalCount, rollbackSnapshot: snapshot) else {
            return finish(request.operationID, .clipboardChanged)
        }
        if let failure = environment.validate(request.target) {
            return finish(request.operationID, failure, clipboard: restore(snapshot, lease: lease))
        }
        guard environment.now < min(captured.expires, request.expiresAt) else {
            return finish(request.operationID, .targetExpired, clipboard: restore(snapshot, lease: lease))
        }
        guard environment.modifiersAreReleased else {
            return finish(request.operationID, .modifiersHeld, clipboard: restore(snapshot, lease: lease))
        }
        guard environment.ownsClipboard(lease) else {
            return finish(request.operationID, .clipboardChanged, clipboard: .newerCopyPreserved)
        }
        environment.postPaste(to: request.target)

        // A grace period is a heuristic, not an acknowledgement from the destination.
        // Cancellation after posting must not skip restoration or cause a second paste.
        await environment.wait(milliseconds: 1000)
        return finish(request.operationID, .pasteSent, clipboard: restore(snapshot, lease: lease))
    }

    private func restore(_ snapshot: InsertionClipboardSnapshot?, lease: InsertionClipboardLease) -> ClipboardDisposition {
        guard environment.ownsClipboard(lease) else { return .newerCopyPreserved }
        guard let snapshot else { return .keptText }
        return environment.restoreClipboard(snapshot, lease: lease) ? .restored : .restorationFailed
    }

    private func response(_ id: UUID, _ status: InsertionStatus) -> InsertionResponse {
        InsertionResponse(operationID: id, status: status)
    }

    private func finish(_ id: UUID, _ status: InsertionStatus,
                        clipboard: ClipboardDisposition = .untouched) -> InsertionResponse {
        let result = InsertionResponse(operationID: id, status: status, clipboard: clipboard)
        completed[id] = result
        completionOrder.append(id)
        if completionOrder.count > 64 { completed.removeValue(forKey: completionOrder.removeFirst()) }
        cancelled.remove(id)
        return result
    }
}
