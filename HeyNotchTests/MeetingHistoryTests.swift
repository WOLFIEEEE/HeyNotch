import Foundation
import XCTest

@MainActor
final class MeetingHistoryTests: XCTestCase {
    private func fixture(_ body: (URL, UserDefaults, Date) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingHistoryTests-" + UUID().uuidString)
        let suite = "MeetingHistoryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("History"), defaults, Date(timeIntervalSince1970: 1_800_000_000))
    }
    private func entry(id: UUID = UUID(), at date: Date, title: String = "Design call", completed: Bool = true,
                       segments: [MeetingTranscriptSegment]? = nil) -> MeetingHistoryEntry {
        MeetingHistoryEntry(id: id, startedAt: date, updatedAt: date, title: title, callSource: "Test call app", elapsed: 40,
            completed: completed, segments: segments ?? [
                .init(source: .microphone, offset: 0, text: "Do not send the invoice."),
                .init(source: .call, offset: 20, text: "नमस्ते café 日本語 👋"),
                .init(source: .call, offset: 39, text: "Audio interrupted", isGap: true)
            ])
    }
    func testDisabledByDefaultNeverCreatesStorage() throws {
        try fixture { directory, defaults, now in
            let store = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now })
            XCTAssertFalse(store.enabled)
            XCTAssertFalse(store.upsert(entry(at: now)))
            XCTAssertNil(store.errorMessage)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }
    func testRoundTripPreservesSessionAndSegmentIDsUnicodeSourcesAndGaps() throws {
        try fixture { directory, defaults, now in
            let store = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now }); store.setEnabled(true)
            let original = entry(at: now)
            XCTAssertTrue(store.upsert(original))
            let reopened = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now })
            XCTAssertEqual(reopened.entries, [original]); XCTAssertTrue(reopened.enabled)
            let file = directory.appendingPathComponent(original.id.uuidString + ".json")
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600); XCTAssertEqual(directoryMode?.intValue, 0o700)
        }
    }
    func testIncompleteSessionIsRecoverableAfterRelaunch() throws {
        try fixture { directory, defaults, now in
            let store = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now }); store.setEnabled(true)
            let original = entry(at: now, completed: false)
            XCTAssertTrue(store.upsert(original))
            let reopened = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now })
            XCTAssertEqual(reopened.entries.first?.id, original.id)
            XCTAssertEqual(reopened.entries.first?.completed, false)
            XCTAssertEqual(reopened.entries.first?.segments.count, 3)
        }
    }
    func testTurningOffPreservesHistoryAndRejectsIncrementalWrites() throws {
        try fixture { directory, defaults, now in
            let store = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now }); store.setEnabled(true)
            let original = entry(at: now); XCTAssertTrue(store.upsert(original)); store.setEnabled(false)
            XCTAssertFalse(store.upsert(entry(id: original.id, at: now, segments: [])))
            let reopened = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now.addingTimeInterval(86400) })
            XCTAssertFalse(reopened.enabled); XCTAssertEqual(reopened.entries, [original])
        }
    }
    func testRetentionUsesRecordingStartInsteadOfRenameOrLatestSnapshot() throws {
        try fixture { directory, defaults, now in
            var clock = now
            let store = MeetingHistoryStore(directory: directory, defaults: defaults, now: { clock }); store.setEnabled(true)
            let original = entry(at: now.addingTimeInterval(-29 * 86400)); XCTAssertTrue(store.upsert(original))
            clock = now.addingTimeInterval(2 * 86400)
            XCTAssertTrue(store.rename(id: original.id, title: "Recent rename"))
            store.reload()
            XCTAssertTrue(store.entries.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(original.id.uuidString + ".json").path))
        }
    }
    func testDisabledHistoryStillExpiresAfterThirtyDays() throws {
        try fixture { directory, defaults, now in
            let store = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now }); store.setEnabled(true)
            let original = entry(at: now); XCTAssertTrue(store.upsert(original)); store.setEnabled(false)
            let reopened = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now.addingTimeInterval(31 * 86400) })
            XCTAssertFalse(reopened.enabled); XCTAssertTrue(reopened.entries.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(original.id.uuidString + ".json").path))
        }
    }
    func testFutureTimestampsCannotEvadeRetention() throws {
        try fixture { directory, defaults, now in
            let store = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now }); store.setEnabled(true)
            XCTAssertFalse(store.upsert(entry(at: now.addingTimeInterval(86400))))
            XCTAssertNotNil(store.errorMessage); XCTAssertTrue(store.entries.isEmpty)
        }
    }
    func testCountRetentionKeepsNewestFiftySessions() throws {
        try fixture { directory, defaults, now in
            let store = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now }); store.setEnabled(true)
            var created: [MeetingHistoryEntry] = []
            for index in 0..<52 {
                let item = entry(at: now.addingTimeInterval(Double(index - 52))); created.append(item)
                XCTAssertTrue(store.upsert(item))
            }
            XCTAssertEqual(store.entries.count, 50)
            XCTAssertFalse(store.contains(id: created[0].id)); XCTAssertFalse(store.contains(id: created[1].id))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.count, 50)
        }
    }
    func testRenamePersistsDuringIncrementalRecordingAndRejectsInvalidTitles() throws {
        try fixture { directory, defaults, now in
            let store = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now }); store.setEnabled(true)
            let original = entry(at: now, completed: false); XCTAssertTrue(store.upsert(original))
            XCTAssertTrue(store.rename(id: original.id, title: "  Client notes  "))
            XCTAssertTrue(store.upsert(entry(id: original.id, at: now.addingTimeInterval(10), title: "Generated title")))
            XCTAssertEqual(store.entries.first?.title, "Client notes")
            XCTAssertEqual(store.entries.first?.startedAt, original.startedAt)
            XCTAssertFalse(store.rename(id: original.id, title: "\n"))
            XCTAssertFalse(store.rename(id: original.id, title: "bad\ntitle"))
            XCTAssertFalse(store.rename(id: original.id, title: String(repeating: "x", count: 121)))
            XCTAssertEqual(store.entries.first?.title, "Client notes")
        }
    }
    func testDeleteAndClearWorkWhileDisabledAndPreventActiveSessionResurrection() throws {
        try fixture { directory, defaults, now in
            let store = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now }); store.setEnabled(true)
            let a = entry(at: now), b = entry(at: now)
            XCTAssertTrue(store.upsert(a)); XCTAssertTrue(store.upsert(b)); store.setEnabled(false)
            XCTAssertTrue(store.delete(id: a.id)); XCTAssertFalse(store.contains(id: a.id))
            XCTAssertTrue(store.clear()); XCTAssertTrue(store.entries.isEmpty)
            store.setEnabled(true)
            XCTAssertFalse(store.upsert(a)); XCTAssertFalse(store.upsert(b)); XCTAssertNil(store.errorMessage)
            XCTAssertTrue(store.upsert(entry(at: now)))
        }
    }
    func testDeletingBeforeFirstSnapshotSuppressesThatID() throws {
        try fixture { directory, defaults, now in
            let store = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now }); store.setEnabled(true)
            let pending = entry(at: now)
            XCTAssertTrue(store.delete(id: pending.id)); XCTAssertFalse(store.upsert(pending))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }
    func testFailedDeletionRemainsVisibleAfterReloadAndCanBeRetried() throws {
        guard getuid() != 0 else { throw XCTSkip("Permission-denial behavior requires a non-root test process.") }
        try fixture { directory, defaults, now in
            let store = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now }); store.setEnabled(true)
            let original = entry(at: now); XCTAssertTrue(store.upsert(original))
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            XCTAssertFalse(store.delete(id: original.id)); XCTAssertNotNil(store.errorMessage)
            store.reload()
            XCTAssertTrue(store.contains(id: original.id))
            XCTAssertFalse(store.upsert(original))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            XCTAssertTrue(store.delete(id: original.id)); XCTAssertFalse(store.contains(id: original.id))
        }
    }
    func testCorruptFileIsVisibleAndNeverAutomaticallyOverwritten() throws {
        try fixture { directory, defaults, now in
            let store = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now }); store.setEnabled(true)
            let original = entry(at: now); XCTAssertTrue(store.upsert(original))
            let file = directory.appendingPathComponent(original.id.uuidString + ".json")
            let broken = Data("{incomplete".utf8); try broken.write(to: file)
            store.reload(); XCTAssertNotNil(store.errorMessage); XCTAssertTrue(store.entries.isEmpty)
            XCTAssertFalse(store.upsert(original)); XCTAssertEqual(try Data(contentsOf: file), broken)
            store.setEnabled(false); XCTAssertFalse(store.upsert(original)); XCTAssertNotNil(store.errorMessage)
            XCTAssertTrue(store.delete(id: original.id)); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }
    func testCorruptionAfterReloadAlsoPreventsAutosaveOverwrite() throws {
        try fixture { directory, defaults, now in
            let store = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now }); store.setEnabled(true)
            let original = entry(at: now); XCTAssertTrue(store.upsert(original))
            let file = directory.appendingPathComponent(original.id.uuidString + ".json")
            let broken = Data("broken".utf8); try broken.write(to: file)
            XCTAssertFalse(store.upsert(original)); XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(try Data(contentsOf: file), broken)
        }
    }
    func testOversizedFileAndSnapshotAreRejectedWithoutReplacingPriorData() throws {
        try fixture { directory, defaults, now in
            let store = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now }); store.setEnabled(true)
            let original = entry(at: now); XCTAssertTrue(store.upsert(original))
            let file = directory.appendingPathComponent(original.id.uuidString + ".json")
            let prior = try Data(contentsOf: file)
            let huge = (0..<40).map { MeetingTranscriptSegment(source: .call, offset: Double($0), text: String(repeating: "x", count: 60_000)) }
            XCTAssertFalse(store.upsert(entry(id: original.id, at: now, segments: huge)))
            XCTAssertEqual(try Data(contentsOf: file), prior)
            let oversized = Data(repeating: 32, count: MeetingHistoryStore.maximumFileBytes + 1)
            try oversized.write(to: file); store.reload()
            XCTAssertNotNil(store.errorMessage); XCTAssertFalse(store.upsert(original))
            XCTAssertEqual(try Data(contentsOf: file).count, oversized.count)
        }
    }
    func testUnwritableStorageErrorIsVisibleAndDoesNotCreateHistoryElsewhere() throws {
        try fixture { directory, defaults, now in
            try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not a folder".utf8).write(to: directory)
            let store = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now }); store.setEnabled(true)
            XCTAssertFalse(store.upsert(entry(at: now))); XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(try String(contentsOf: directory), "not a folder")
        }
    }
    func testHistoryNeverFollowsSymlinkDirectory() throws {
        try fixture { directory, defaults, now in
            let outside = directory.deletingLastPathComponent().appendingPathComponent("Outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
            let store = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now }); store.setEnabled(true)
            XCTAssertFalse(store.upsert(entry(at: now))); XCTAssertNotNil(store.errorMessage)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }
    func testClearDoesNotRecursivelyDeleteAnUnexpectedDirectory() throws {
        try fixture { directory, defaults, now in
            let unexpected = directory.appendingPathComponent(UUID().uuidString + ".json")
            try FileManager.default.createDirectory(at: unexpected, withIntermediateDirectories: true)
            let keep = unexpected.appendingPathComponent("keep.txt")
            try Data("do not delete".utf8).write(to: keep)
            let store = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now })
            XCTAssertFalse(store.clear()); XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(try String(contentsOf: keep), "do not delete")
        }
    }
    func testClearRemovesOrphanSnapshotWhileLeavingUnrelatedFilesAlone() throws {
        try fixture { directory, defaults, now in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let orphan = directory.appendingPathComponent(".snapshot-" + UUID().uuidString)
            let unrelated = directory.appendingPathComponent("notes.txt")
            try Data("partial private transcript".utf8).write(to: orphan); try Data("keep".utf8).write(to: unrelated)
            let store = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now })
            XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
            // A temporary left after the last reload must also be removed by Clear.
            try Data("another partial transcript".utf8).write(to: orphan)
            XCTAssertTrue(store.clear())
            XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
            XCTAssertEqual(try String(contentsOf: unrelated), "keep")
        }
    }
    func testClearPreservesUnknownJSONAndItsWarningWhileRemovingOwnedSessions() throws {
        try fixture { directory, defaults, now in
            let store = MeetingHistoryStore(directory: directory, defaults: defaults, now: { now }); store.setEnabled(true)
            let original = entry(at: now); XCTAssertTrue(store.upsert(original))
            let unrelated = directory.appendingPathComponent("notes.json")
            let content = Data("{\"note\":\"keep this unrelated document\"}".utf8)
            try content.write(to: unrelated)
            store.reload(); XCTAssertNotNil(store.errorMessage)
            XCTAssertTrue(store.clear()); XCTAssertTrue(store.entries.isEmpty)
            XCTAssertEqual(try Data(contentsOf: unrelated), content)
            XCTAssertNotNil(store.errorMessage)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(original.id.uuidString + ".json").path))
            XCTAssertFalse(store.upsert(entry(at: now)))
            XCTAssertEqual(try Data(contentsOf: unrelated), content)
        }
    }
}
