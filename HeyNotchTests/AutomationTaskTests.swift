import XCTest

@MainActor
final class AutomationTaskTests: XCTestCase {
    private func fixture(_ body: (AutomationTaskEngine, TaskBoardStore, AutomationRepository, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HeyNotchAutomationTests-" + UUID().uuidString)
        let suite = "HeyNotchTests.automation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let repository = AutomationRepository()
        let board = TaskBoardStore(repository: repository, defaults: defaults)
        board.selectedListID = "list"; await board.refresh()
        let url = directory.appendingPathComponent("operations.json")
        let engine = AutomationTaskEngine(board: board, journalURL: url)
        try await body(engine, board, repository, url)
    }
    private func context(_ client: String = "client", lists: Set<String> = ["list"], write: Bool = true) -> AutomationContext {
        .init(clientID: client, allowedListIDs: lists, canWrite: write)
    }
    private func call(_ engine: AutomationTaskEngine, _ tool: String, _ arguments: [String: Any] = [:],
                      context: AutomationContext? = nil) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["tool": tool, "arguments": arguments])
        let response = await engine.execute(data, context: context ?? self.context())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
    }
    private func code(_ response: [String: Any]) -> String? { (response["error"] as? [String: Any])?["code"] as? String }
    private func task(_ response: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap((response["result"] as? [String: Any])?["task"] as? [String: Any])
    }
    private func revision(_ engine: AutomationTaskEngine) async throws -> String {
        let response = try await call(engine, "get_task", ["taskID": "task"])
        return try XCTUnwrap(task(response)["revision"] as? String)
    }
    private func waitForFetch(_ repository: AutomationRepository) async throws {
        let deadline = Date().addingTimeInterval(2)
        while repository.fetchContinuation == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertNotNil(repository.fetchContinuation)
    }

    func testCreateReadbackPreservesDraftSelectionAndReturnsCanonicalTask() async throws {
        try await fixture { engine, board, repository, url in
            board.selectedListID = "other"; board.makeDraft("My unsaved private task")
            let original = board.draft
            let operation = UUID().uuidString
            let response = try await call(engine, "create_task", ["operationID": operation, "listID": "list", "title": "  Agent task  ", "notes": "Context"])
            let created = try task(response)
            XCTAssertEqual(created["title"] as? String, "Agent task")
            XCTAssertEqual(created["notes"] as? String, "Context")
            XCTAssertEqual(created["column"] as? String, "todo")
            XCTAssertEqual((created["revision"] as? String)?.count, 64)
            XCTAssertEqual(board.draft, original); XCTAssertEqual(board.selectedListID, "other")
            XCTAssertEqual(repository.saveCount, 1); XCTAssertEqual(repository.accessRequests, 0)
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
            let parentMode = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(parentMode?.intValue, 0o700)
        }
    }

    func testSameOperationReplaysAcrossEngineRestartAndPayloadConflictDoesNotWrite() async throws {
        try await fixture { engine, board, repository, url in
            let args: [String: Any] = ["operationID": UUID().uuidString, "listID": "list", "title": "Only once"]
            let first = try await call(engine, "create_task", args)
            let reopened = AutomationTaskEngine(board: board, journalURL: url)
            let second = try await call(reopened, "create_task", args)
            XCTAssertEqual(try AutomationJSON.encode(first), try AutomationJSON.encode(second))
            var changed = args; changed["title"] = "Different request"
            let conflict = try await call(reopened, "create_task", changed)
            XCTAssertEqual(code(conflict), "operation_conflict")
            XCTAssertEqual(repository.saveCount, 1)
        }
    }

    func testDifferentClientsWithSameOperationUUIDHaveIndependentInternalSaveIDs() async throws {
        try await fixture { engine, _, repository, _ in
            let args: [String: Any] = ["operationID": UUID().uuidString, "listID": "list", "title": "Client task"]
            let first = try task(await call(engine, "create_task", args, context: context("first")))
            let second = try task(await call(engine, "create_task", args, context: context("second")))
            XCTAssertNotEqual(first["id"] as? String, second["id"] as? String)
            XCTAssertEqual(Set(repository.savedOperationIDs).count, 2)
            XCTAssertEqual(repository.saveCount, 2)
        }
    }

    func testScopeFiltersReadsAndDeniesWritesAndReplayOutsideGrant() async throws {
        try await fixture { engine, _, repository, _ in
            let found = try await call(engine, "find_tasks")
            let items = (found["result"] as? [String: Any])?["tasks"] as? [[String: Any]]
            XCTAssertEqual(items?.count, 1)
            XCTAssertEqual(items?.first?["id"] as? String, "task")
            let hidden = try await call(engine, "get_task", ["taskID": "secret"])
            XCTAssertEqual(code(hidden), "access_denied")
            let denied = try await call(engine, "create_task", ["operationID": UUID().uuidString, "listID": "other", "title": "No access"])
            XCTAssertEqual(code(denied), "access_denied"); XCTAssertEqual(repository.saveCount, 0)
            let args: [String: Any] = ["operationID": UUID().uuidString, "listID": "list", "title": "Allowed"]
            _ = try await call(engine, "create_task", args)
            let replay = try await call(engine, "create_task", args, context: context(lists: ["other"]))
            XCTAssertEqual(code(replay), "access_denied"); XCTAssertNil(replay["result"])
            let readOnly = try await call(engine, "create_task", args, context: context(write: false))
            XCTAssertEqual(code(readOnly), "access_denied"); XCTAssertEqual(repository.saveCount, 1)
        }
    }

    func testRevisionConflictIncludesExternalChangesAndLocalDoingChanges() async throws {
        try await fixture { engine, board, repository, _ in
            let old = try await revision(engine)
            repository.values[0].notes = "Changed elsewhere"
            let update = try await call(engine, "update_task", ["operationID": UUID().uuidString, "taskID": "task", "expectedRevision": old, "title": "Stale"])
            XCTAssertEqual(code(update), "revision_conflict"); XCTAssertEqual(repository.saveCount, 0)
            let refreshed = try await revision(engine)
            await board.moveTask(repository.values[0], to: .doing)
            let completion = try await call(engine, "set_task_completed", ["operationID": UUID().uuidString, "taskID": "task", "expectedRevision": refreshed, "completed": true])
            XCTAssertEqual(code(completion), "revision_conflict"); XCTAssertEqual(repository.completeCount, 0)
        }
    }

    func testDoingMovesDoNotWriteReminderAndTitleEditPreservesAlarmsAndDates() async throws {
        try await fixture { engine, _, repository, _ in
            let original = repository.values[0]
            let firstRevision = try await revision(engine)
            let moved = try task(await call(engine, "move_task", ["operationID": UUID().uuidString, "taskID": "task", "expectedRevision": firstRevision, "column": "doing"]))
            XCTAssertEqual(moved["column"] as? String, "doing")
            XCTAssertEqual(repository.values[0], original); XCTAssertEqual(repository.completeCount, 0)
            let updated = try await call(engine, "update_task", ["operationID": UUID().uuidString, "taskID": "task", "expectedRevision": moved["revision"]!, "title": "Renamed"])
            XCTAssertEqual(try task(updated)["column"] as? String, "doing")
            XCTAssertEqual(repository.values[0].alarms, original.alarms)
            XCTAssertEqual(repository.values[0].due, original.due)
            XCTAssertEqual(repository.values[0].notes, original.notes)
        }
    }

    func testStrictDatesBooleansAndUnknownFieldsNeverWrite() async throws {
        try await fixture { engine, _, repository, _ in
            let invalidDates: [[String: Any]] = [
                ["year": 2026, "month": 2, "day": 30],
                ["year": 2026, "month": 11, "day": 5, "hour": 10],
                ["year": 2026, "month": 11, "day": 5, "hour": 10, "minute": 30, "timeZoneIdentifier": "Not/AZone"],
                ["year": true, "month": 11, "day": 5],
                ["year": 2026, "month": 3, "day": 8, "hour": 2, "minute": 30, "timeZoneIdentifier": "America/Los_Angeles"]
            ]
            for due in invalidDates {
                let response = try await call(engine, "create_task", ["operationID": UUID().uuidString, "listID": "list", "title": "Invalid date", "due": due])
                XCTAssertEqual(response["ok"] as? Bool, false)
            }
            let rev = try await revision(engine)
            let numericBool = try await call(engine, "set_task_completed", ["operationID": UUID().uuidString, "taskID": "task", "expectedRevision": rev, "completed": 1])
            XCTAssertEqual(code(numericBool), "invalid_arguments")
            let unknown = try await call(engine, "create_task", ["operationID": UUID().uuidString, "listID": "list", "title": "Test", "recurring": true])
            XCTAssertEqual(code(unknown), "invalid_arguments")
            XCTAssertEqual(repository.saveCount + repository.completeCount, 0)
        }
    }

    func testNormalizedTimedDueAndClearDueReadBackExactly() async throws {
        try await fixture { engine, _, repository, _ in
            let due: [String: Any] = ["year": 2026, "month": 11, "day": 7, "hour": 10, "minute": 30, "timeZoneIdentifier": "UTC"]
            let created = try task(await call(engine, "create_task", ["operationID": UUID().uuidString, "listID": "list", "title": "Timed", "due": due, "alarm": "atDue"]))
            let returnedDue = try XCTUnwrap(created["due"] as? [String: Any])
            XCTAssertEqual(returnedDue["timeZoneIdentifier"] as? String, TimeZone(identifier: "UTC")?.identifier)
            let cleared = try task(await call(engine, "update_task", ["operationID": UUID().uuidString, "taskID": created["id"]!, "expectedRevision": created["revision"]!, "clearDue": true, "alarm": "off"]))
            XCTAssertTrue(cleared["due"] is NSNull)
            XCTAssertTrue(repository.values.last!.alarms.isEmpty)
        }
    }

    func testReadbackFailureIsUncertainAndCannotAutomaticallyReplayWrite() async throws {
        try await fixture { engine, board, repository, url in
            repository.failFetchAfterWrite = true
            let operation = UUID().uuidString
            let args: [String: Any] = ["operationID": operation, "listID": "list", "title": "May have saved"]
            let first = try await call(engine, "create_task", args)
            XCTAssertEqual(code(first), "outcome_uncertain"); XCTAssertEqual(repository.saveCount, 1)
            repository.failFetch = false
            let reopened = AutomationTaskEngine(board: board, journalURL: url)
            let replay = try await call(reopened, "create_task", args)
            XCTAssertEqual(code(replay), "outcome_uncertain"); XCTAssertEqual(repository.saveCount, 1)
            let operationStatus = try await call(reopened, "get_operation", ["operationID": operation])
            XCTAssertEqual((operationStatus["result"] as? [String: Any])?["status"] as? String, "uncertain")
        }
    }

    func testPermissionAndReadOnlyListsNeverPromptOrWrite() async throws {
        try await fixture { engine, _, repository, _ in
            repository.permitted = false
            let denied = try await call(engine, "create_task", ["operationID": UUID().uuidString, "listID": "list", "title": "No permission"])
            XCTAssertEqual(code(denied), "permission_required")
            repository.permitted = true; repository.writable = false
            let readonly = try await call(engine, "create_task", ["operationID": UUID().uuidString, "listID": "list", "title": "Read only"])
            XCTAssertEqual(code(readonly), "read_only")
            XCTAssertEqual(repository.accessRequests, 0); XCTAssertEqual(repository.saveCount, 0)
        }
    }

    func testDuplicateConcurrentRequestsShareSingleWrite() async throws {
        try await fixture { engine, _, repository, _ in
            repository.holdNextFetch = true
            let args: [String: Any] = ["operationID": UUID().uuidString, "listID": "list", "title": "Concurrent"]
            let first = Task { try await self.call(engine, "create_task", args) }
            try await waitForFetch(repository)
            let second = Task { try await self.call(engine, "create_task", args) }
            repository.releaseFetch()
            let a = try await first.value, b = try await second.value
            XCTAssertEqual(try AutomationJSON.encode(a), try AutomationJSON.encode(b))
            XCTAssertEqual(repository.saveCount, 1)
        }
    }

    func testAutomationWaitsForUIQueueAndRechecksRevisionAfterCompletion() async throws {
        try await fixture { engine, board, repository, _ in
            let oldRevision = try await revision(engine)
            repository.holdNextFetch = true
            let ui = Task { await board.moveTask(repository.values[0], to: .done) }
            try await waitForFetch(repository)
            let automation = Task { try await self.call(engine, "update_task", ["operationID": UUID().uuidString, "taskID": "task", "expectedRevision": oldRevision, "title": "Stale edit"]) }
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertEqual(repository.saveCount, 0); XCTAssertTrue(board.pendingTaskIDs.contains("task"))
            repository.releaseFetch(); await ui.value
            let result = try await automation.value
            XCTAssertEqual(code(result), "revision_conflict"); XCTAssertEqual(repository.saveCount, 0)
            XCTAssertTrue(board.pendingTaskIDs.isEmpty)
        }
    }

    func testRevocationDuringReadAndWhileQueuedHidesDataAndPreventsMutation() async throws {
        try await fixture { engine, _, repository, _ in
            var enabled = true
            let grant = AutomationContext(clientID: "client", allowedListIDs: ["list"], canWrite: true, authorizationCheck: { enabled })
            repository.holdNextFetch = true
            let reading = Task { try await self.call(engine, "get_task", ["taskID": "task"], context: grant) }
            try await waitForFetch(repository)
            let queued = Task { try await self.call(engine, "create_task", ["operationID": UUID().uuidString, "listID": "list", "title": "Revoked"], context: grant) }
            enabled = false; repository.releaseFetch()
            let readResult = try await reading.value, writeResult = try await queued.value
            XCTAssertEqual(code(readResult), "access_denied"); XCTAssertNil(readResult["result"])
            XCTAssertEqual(code(writeResult), "access_denied"); XCTAssertEqual(repository.saveCount, 0)
        }
    }

    func testRecurringCompletionIsExplicitlyUnsupportedButLocalDoingStillWorks() async throws {
        try await fixture { engine, _, repository, _ in
            repository.values[0].recurring = true
            let rev = try await revision(engine)
            let completed = try await call(engine, "set_task_completed", ["operationID": UUID().uuidString, "taskID": "task", "expectedRevision": rev, "completed": true])
            XCTAssertEqual(code(completed), "unsupported_recurring"); XCTAssertEqual(repository.completeCount, 0)
            let doing = try task(await call(engine, "move_task", ["operationID": UUID().uuidString, "taskID": "task", "expectedRevision": rev, "column": "doing"]))
            XCTAssertEqual(doing["column"] as? String, "doing"); XCTAssertEqual(repository.completeCount, 0)
        }
    }

    func testCorruptAndUnwritableJournalFailBeforeAnyMutation() async throws {
        try await fixture { _, board, repository, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not-json".utf8).write(to: url)
            let corrupt = AutomationTaskEngine(board: board, journalURL: url)
            let args: [String: Any] = ["operationID": UUID().uuidString, "listID": "list", "title": "No write"]
            let corruptResult = try await call(corrupt, "create_task", args)
            XCTAssertEqual(code(corruptResult), "journal_unavailable")
            let inaccessible = AutomationTaskEngine(board: board, journalURL: url.appendingPathComponent("blocked.json"))
            let inaccessibleResult = try await call(inaccessible, "create_task", args)
            XCTAssertEqual(code(inaccessibleResult), "journal_unavailable")
            XCTAssertEqual(repository.saveCount, 0)
        }
    }

    func testRetiringRevokedClientRemovesOnlyItsDurableNamespace() async throws {
        try await fixture { engine, board, repository, url in
            let operation = UUID().uuidString
            let args: [String: Any] = ["operationID": operation, "listID": "list", "title": "Client task"]
            _ = try await call(engine, "create_task", args, context: context("retired"))
            _ = try await call(engine, "create_task", args, context: context("retained"))
            let retired = await engine.retireClient("retired")
            XCTAssertTrue(retired)
            let reopened = AutomationTaskEngine(board: board, journalURL: url)
            let missing = try await call(reopened, "get_operation", ["operationID": operation], context: context("retired"))
            XCTAssertEqual(code(missing), "not_found")
            let retained = try await call(reopened, "create_task", args, context: context("retained"))
            XCTAssertEqual(retained["ok"] as? Bool, true); XCTAssertEqual(repository.saveCount, 2)
        }
    }

    func testRecoveredPendingOperationIsUncertainWithoutAnotherWrite() async throws {
        try await fixture { _, board, repository, url in
            let operation = UUID()
            let args: [String: Any] = ["operationID": operation.uuidString, "listID": "list", "title": "Interrupted"]
            let fingerprint = AutomationJSON.hash(try AutomationJSON.encode(["tool": "create_task", "arguments": args]))
            let journal = AutomationJournal(url: url)
            try await journal.begin(.init(clientID: "client", operationID: operation, fingerprint: fingerprint,
                                          internalID: UUID(), listIDs: ["list"], state: .pending, response: nil))
            let recovered = AutomationTaskEngine(board: board, journalURL: url)
            let result = try await call(recovered, "create_task", args)
            XCTAssertEqual(code(result), "outcome_uncertain"); XCTAssertEqual(repository.saveCount, 0)
            let state = try await call(recovered, "get_operation", ["operationID": operation.uuidString])
            XCTAssertEqual((state["result"] as? [String: Any])?["status"] as? String, "uncertain")
        }
    }

    func testFullJournalRejectsNewKeyButRetainsExistingReplay() async throws {
        try await fixture { _, board, repository, url in
            var entries: [String: AutomationJournal.Entry] = [:]
            for _ in 0..<AutomationJournal.maximumEntries {
                let id = UUID()
                entries[AutomationJournal.key(clientID: "client", operationID: id)] = .init(
                    clientID: "client", operationID: id, fingerprint: String(repeating: "0", count: 64),
                    internalID: UUID(), listIDs: ["list"], state: .pending, response: nil)
            }
            struct Envelope: Encodable { let version = 1; let entries: [String: AutomationJournal.Entry] }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Envelope(entries: entries)).write(to: url)
            let engine = AutomationTaskEngine(board: board, journalURL: url)
            let response = try await call(engine, "create_task", ["operationID": UUID().uuidString, "listID": "list", "title": "Cannot start"])
            XCTAssertEqual(code(response), "journal_full"); XCTAssertEqual(repository.saveCount, 0)
            let existing = try XCTUnwrap(entries.values.first)
            let status = try await call(engine, "get_operation", ["operationID": existing.operationID.uuidString])
            XCTAssertEqual((status["result"] as? [String: Any])?["status"] as? String, "uncertain")
        }
    }

    func testRevocationAfterWriteHidesResponseButPreservesVerifiedOutcome() async throws {
        try await fixture { engine, _, repository, _ in
            var enabled = true
            let grant = AutomationContext(clientID: "client", allowedListIDs: ["list"], canWrite: true, authorizationCheck: { enabled })
            repository.onWrite = { enabled = false }
            let operation = UUID().uuidString
            let result = try await call(engine, "create_task", ["operationID": operation, "listID": "list", "title": "Written before revocation"], context: grant)
            XCTAssertEqual(code(result), "access_denied"); XCTAssertNil(result["result"])
            XCTAssertEqual(repository.saveCount, 1)
            // Inspect with a trusted test context to verify journal finalization;
            // the revoked real grant remains rejected by authorizationCheck.
            let state = try await call(engine, "get_operation", ["operationID": operation])
            XCTAssertEqual((state["result"] as? [String: Any])?["status"] as? String, "succeeded")
        }
    }

    func testFindPaginationIsScopedAndMalformedJSONIsRejected() async throws {
        try await fixture { engine, _, repository, _ in
            for index in 0..<4 {
                repository.values.append(.init(id: "page-\(index)", title: "Match \(index)", notes: "", due: nil, completed: index == 3, listID: "list", alarms: [], recurring: false))
            }
            let result = try await call(engine, "find_tasks", ["query": "match", "completed": false, "limit": 2, "offset": 0])
            let page = try XCTUnwrap(result["result"] as? [String: Any])
            XCTAssertEqual(page["total"] as? Int, 3); XCTAssertEqual(page["nextOffset"] as? Int, 2)
            XCTAssertEqual((page["tasks"] as? [[String: Any]])?.count, 2)
            let raw = await engine.execute(Data("{not-json".utf8), context: context())
            let invalid = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
            XCTAssertEqual(code(invalid), "invalid_arguments")
        }
    }

    func testExternalEditOrListMoveDuringJournalCommitCannotBeOverwritten() async throws {
        for moveOutsideGrant in [false, true] {
            try await fixture { engine, _, repository, url in
                let originalRevision = try await revision(engine)
                var changedAfterCommit = false
                let grant = AutomationContext(clientID: "client", allowedListIDs: ["list"], canWrite: true, authorizationCheck: {
                    // Simulate another Reminders writer observing the durable
                    // journal boundary. The engine has yielded off MainActor,
                    // so its earlier fetched reminder is now stale.
                    if !changedAfterCommit, FileManager.default.fileExists(atPath: url.path) {
                        changedAfterCommit = true
                        repository.values[0].notes = "External edit during commit"
                        if moveOutsideGrant { repository.values[0].listID = "other" }
                    }
                    return true
                })
                let result = try await call(engine, "update_task", ["operationID": UUID().uuidString,
                    "taskID": "task", "expectedRevision": originalRevision, "title": "Would overwrite"], context: grant)
                XCTAssertTrue(changedAfterCommit)
                XCTAssertEqual(code(result), moveOutsideGrant ? "access_denied" : "revision_conflict")
                XCTAssertEqual(repository.saveCount, 0)
                XCTAssertEqual(repository.values[0].notes, "External edit during commit")
                XCTAssertEqual(repository.values[0].listID, moveOutsideGrant ? "other" : "list")
            }
        }
    }
}

@MainActor
private final class AutomationRepository: TaskRepository {
    var values: [ReminderTask] = [
        .init(id: "task", title: "Original", notes: "Keep my notes", due: .init(year: 2026, month: 11, day: 10), completed: false, listID: "list", alarms: [.init(absoluteDate: nil, relativeOffset: -300)], recurring: false),
        .init(id: "secret", title: "Hidden list title", notes: "Private", due: nil, completed: false, listID: "other", alarms: [], recurring: false)
    ]
    var permitted = true
    var writable = true
    var accessRequests = 0
    var saveCount = 0
    var completeCount = 0
    var savedOperationIDs: [UUID] = []
    var failFetch = false
    var failFetchAfterWrite = false
    var holdNextFetch = false
    var fetchContinuation: CheckedContinuation<Void, Never>?
    var onWrite: (() -> Void)?
    func requestAccess() async throws { accessRequests += 1 }
    func lists() throws -> [TaskList] {
        guard permitted else { throw TaskServiceError.permission }
        return ["list", "other"].map { .init(id: $0, title: $0, account: "Fixture", isLocal: true, writable: writable) }
    }
    func fetch() async throws -> [ReminderTask] {
        guard permitted else { throw TaskServiceError.permission }
        if failFetch { throw TaskServiceError.fetchFailed }
        let result = values
        if holdNextFetch {
            holdNextFetch = false
            await withCheckedContinuation { fetchContinuation = $0 }
        }
        return result
    }
    func releaseFetch() { fetchContinuation?.resume(); fetchContinuation = nil }
    func save(_ draft: TaskDraft) async throws -> String {
        saveCount += 1; savedOperationIDs.append(draft.id)
        let old = values.first { $0.id == draft.reminderID }
        let id = draft.reminderID ?? draft.id.uuidString
        let alarms: [TaskAlarm]
        switch draft.alarm {
        case .keep: alarms = old?.alarms ?? []
        case .off: alarms = []
        case .atDue:
            if let due = draft.due, due.hasTime, let date = due.date(in: .current) { alarms = [.init(absoluteDate: date, relativeOffset: 0)] }
            else { alarms = [] }
        }
        let value = ReminderTask(id: id, title: draft.title, notes: draft.notes, due: draft.due,
                                 completed: old?.completed ?? false, listID: draft.listID, alarms: alarms, recurring: old?.recurring ?? false)
        if let index = values.firstIndex(where: { $0.id == id }) { values[index] = value }
        else { values.append(value) }
        if failFetchAfterWrite { failFetch = true }
        onWrite?()
        return id
    }
    func complete(_ id: String, completed: Bool) throws {
        guard let index = values.firstIndex(where: { $0.id == id }) else { throw TaskServiceError.missing }
        completeCount += 1; values[index].completed = completed
        if failFetchAfterWrite { failFetch = true }
        onWrite?()
    }
    func delete(_ id: String) throws { values.removeAll { $0.id == id } }
}
