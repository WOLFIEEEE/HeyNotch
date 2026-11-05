import Foundation
import XCTest

@MainActor
final class ShelfCleanupPolicyTests: XCTestCase {
    private actor ValidationGate {
        private var started = false
        private var waitingForStart: CheckedContinuation<Void, Never>?
        private var result: CheckedContinuation<Bool, Never>?

        func validate(_ data: Data) async -> Bool {
            started = true
            waitingForStart?.resume()
            waitingForStart = nil
            return await withCheckedContinuation { result = $0 }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { waitingForStart = $0 }
        }

        func finish(valid: Bool) {
            result?.resume(returning: valid)
            result = nil
        }
    }

    private func snapshot(_ bytes: String, id: UUID = UUID()) -> ShelfBookmarkSnapshot {
        ShelfBookmarkSnapshot(id: id, bookmark: Data(bytes.utf8))
    }

    func testAdditionDuringSuspendedValidationSurvives() async {
        let original = snapshot("invalid old file")
        let added = snapshot("new drop")
        var current = [original]
        let gate = ValidationGate()
        let cleanup = Task {
            let invalid = await ShelfCleanupPolicy.invalidSnapshots(in: current) { await gate.validate($0) }
            let removed = ShelfCleanupPolicy.removalIDs(current: current, invalid: invalid)
            current.removeAll { removed.contains($0.id) }
        }
        await gate.waitUntilStarted()
        current.append(added)
        await gate.finish(valid: false)
        await cleanup.value
        XCTAssertEqual(current, [added])
    }

    func testRemovalDuringSuspendedValidationIsNotResurrected() async {
        let original = snapshot("valid old file")
        var current = [original]
        let gate = ValidationGate()
        let cleanup = Task {
            let invalid = await ShelfCleanupPolicy.invalidSnapshots(in: current) { await gate.validate($0) }
            let removed = ShelfCleanupPolicy.removalIDs(current: current, invalid: invalid)
            current.removeAll { removed.contains($0.id) }
        }
        await gate.waitUntilStarted()
        current.removeAll()
        await gate.finish(valid: true)
        await cleanup.value
        XCTAssertTrue(current.isEmpty)
    }

    func testRefreshedBookmarkDuringValidationIsNeverRemovedByStaleResult() async {
        let original = snapshot("stale bookmark")
        let refreshed = snapshot("refreshed bookmark", id: original.id)
        var current = [original]
        let gate = ValidationGate()
        let cleanup = Task {
            let invalid = await ShelfCleanupPolicy.invalidSnapshots(in: current) { await gate.validate($0) }
            let removed = ShelfCleanupPolicy.removalIDs(current: current, invalid: invalid)
            current.removeAll { removed.contains($0.id) }
        }
        await gate.waitUntilStarted()
        current = [refreshed]
        await gate.finish(valid: false)
        await cleanup.value
        XCTAssertEqual(current, [refreshed])
    }

    func testOnlyInvalidUnchangedBookmarksAreEligibleForCleanup() async {
        let invalid = snapshot("bad")
        let valid = snapshot("good")
        let deleted = snapshot("bad")
        let refreshedOld = snapshot("bad")
        let refreshedNew = snapshot("new", id: refreshedOld.id)
        let added = snapshot("bad")
        let results = await ShelfCleanupPolicy.invalidSnapshots(in: [invalid, valid, deleted, refreshedOld]) {
            $0 != Data("bad".utf8)
        }
        XCTAssertEqual(results, [invalid, deleted, refreshedOld])
        XCTAssertEqual(ShelfCleanupPolicy.removalIDs(current: [invalid, valid, refreshedNew, added], invalid: results), [invalid.id])
    }

    func testCancellationDiscardsPartialValidationResults() async {
        let original = snapshot("bad")
        let gate = ValidationGate()
        let cleanup = Task {
            await ShelfCleanupPolicy.invalidSnapshots(in: [original]) { await gate.validate($0) }
        }
        await gate.waitUntilStarted()
        cleanup.cancel()
        await gate.finish(valid: false)
        let results = await cleanup.value
        XCTAssertTrue(results.isEmpty)
    }

    func testEmptySnapshotDoesNotInvokeValidation() async {
        let results = await ShelfCleanupPolicy.invalidSnapshots(in: []) { _ in
            XCTFail("No files should be validated")
            return false
        }
        XCTAssertTrue(results.isEmpty)
    }
}
