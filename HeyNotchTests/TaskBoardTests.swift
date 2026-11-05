import XCTest

@MainActor
final class TaskBoardTests: XCTestCase {
    private func check(_ body: (TaskBoardStore, FixtureTaskRepository, UserDefaults) async throws -> Void) async rethrows {
        let defaults = TaskBoardMemoryDefaults()
        let repository = FixtureTaskRepository()
        let store = TaskBoardStore(repository: repository, defaults: defaults)
        store.selectedListID = "list"
        try await body(store, repository, defaults)
    }
    func testUndatedTasksRemainVisibleAfterReload() async {
        await check { store, repository, defaults in
            store.makeDraft("buy milk"); await store.saveDraft()
            XCTAssertEqual(store.visibleTasks.count, 1); XCTAssertNil(store.visibleTasks.first?.due)
            let reopened = TaskBoardStore(repository: repository, defaults: defaults)
            await reopened.refresh()
            XCTAssertEqual(reopened.visibleTasks.first?.title, "buy milk")
        }
    }
    func testFailedSaveKeepsExactDraftAndDoesNotClaimSuccess() async {
        await check { store, repository, _ in
            store.makeDraft("call Sam"); let original = store.draft
            repository.failSave = true; await store.saveDraft()
            XCTAssertEqual(store.draft, original); XCTAssertNotNil(store.errorMessage)
            XCTAssertNil(store.lastSavedID); XCTAssertTrue(store.tasks.isEmpty)
        }
    }
    func testUndoDeletesExactCreatedIDAndPersistsAcrossReopen() async {
        await check { store, repository, defaults in
            store.makeDraft("first"); await store.saveDraft(); let first = store.lastSavedID
            store.makeDraft("second"); await store.saveDraft(); let second = store.lastSavedID
            XCTAssertNotEqual(first, second)
            let reopened = TaskBoardStore(repository: repository, defaults: defaults)
            await reopened.undoLastSave()
            XCTAssertEqual(repository.deletedIDs, [second!])
            XCTAssertTrue(repository.values.contains { $0.id == first }); XCTAssertNil(reopened.lastSavedID)
        }
    }
    func testAmbiguousDraftCannotSaveWithoutAcknowledgement() async {
        await check { store, repository, _ in
            store.makeDraft("take medicine every day at 8"); await store.saveDraft()
            XCTAssertTrue(repository.values.isEmpty); XCTAssertNotNil(store.draft)
        }
    }
    func testCompletionEditAndDeletion() async {
        await check { store, _, _ in
            store.makeDraft("buy milk"); await store.saveDraft()
            let original = store.tasks[0]
            await store.setCompleted(original, true); XCTAssertTrue(store.tasks[0].completed)
            store.edit(store.tasks[0]); store.draft?.title = "buy oat milk"; await store.saveDraft()
            XCTAssertEqual(store.tasks.count, 1); XCTAssertEqual(store.tasks[0].title, "buy oat milk")
            await store.delete(store.tasks[0]); XCTAssertTrue(store.tasks.isEmpty)
        }
    }
    func testRefreshDoesNotOverwriteUnsavedDraft() async {
        await check { store, _, _ in
            store.makeDraft("a draft"); let id = store.draft?.id
            await store.refresh(); XCTAssertEqual(store.draft?.id, id); XCTAssertEqual(store.draft?.title, "a draft")
        }
    }
    func testNewVoiceAndEditProposalsCannotSilentlyReplaceUnsavedDraft() async {
        await check { store, repository, _ in
            XCTAssertTrue(store.makeDraft("Original task"))
            store.draft?.notes = "Unsaved notes 📝"
            let original = store.draft
            XCTAssertFalse(store.makeDraft())
            XCTAssertEqual(store.draft, original)
            XCTAssertFalse(store.makeDraft("A new voice task"))
            XCTAssertEqual(store.draft, original)
            store.edit(ReminderTask(id: "other", title: "Other reminder", notes: "", due: nil,
                                    completed: false, listID: "list", alarms: [], recurring: false))
            XCTAssertEqual(store.draft, original)
            XCTAssertTrue(repository.values.isEmpty)
        }
    }
    func testDraftReplacementRequiresExactApprovedSnapshot() async throws {
        try await check { store, repository, _ in
            store.makeDraft("Original task")
            let approved = try XCTUnwrap(store.draft)
            let replacement = store.makeDraftProposal("New task")
            store.draft?.notes = "Changed while confirmation was open"
            XCTAssertFalse(store.stageDraft(replacement, replacing: approved))
            XCTAssertEqual(store.draft?.notes, "Changed while confirmation was open")
            let current = try XCTUnwrap(store.draft)
            XCTAssertTrue(store.stageDraft(replacement, replacing: current))
            XCTAssertEqual(store.draft, replacement)
            XCTAssertTrue(repository.values.isEmpty)
        }
    }
    func testSavingRejectsCancelAndReplacementUntilPostCommitRefreshFinishes() async throws {
        try await check { store, repository, _ in
            await store.refresh()
            store.makeDraft("Keep the editor while saving")
            let original = try XCTUnwrap(store.draft)
            repository.suspendNextFetch = true
            let save = Task { await store.saveDraft() }
            while repository.pendingFetch == nil { await Task.yield() }
            XCTAssertTrue(store.saving)
            XCTAssertEqual(repository.values.count, 1, "The save has committed; Cancel cannot undo it.")
            XCTAssertFalse(store.discardDraft())
            XCTAssertFalse(store.makeDraft("Another task"))
            XCTAssertFalse(store.stageDraft(store.makeDraftProposal("Approved replacement"), replacing: original))
            store.edit(repository.values[0])
            XCTAssertEqual(store.draft, original)
            repository.finishFetch(with: repository.values)
            await save.value
            XCTAssertFalse(store.saving)
            XCTAssertNil(store.draft)
            XCTAssertEqual(repository.values.count, 1)
        }
    }
    func testCancelOutsideSaveClearsOnlyDraftWithoutWriting() async {
        await check { store, repository, _ in
            store.makeDraft("Unsaved")
            XCTAssertTrue(store.discardDraft())
            XCTAssertNil(store.draft)
            XCTAssertTrue(repository.values.isEmpty)
        }
    }
    func testSuccessfulRefreshClearsUndoForExternallyDeletedTaskAndPersistsIt() async {
        await check { store, repository, defaults in
            store.makeDraft("Deleted elsewhere"); await store.saveDraft()
            XCTAssertNotNil(store.lastSavedID)
            repository.values.removeAll()
            await store.refresh()
            XCTAssertNil(store.lastSavedID)
            XCTAssertNil(defaults.string(forKey: "tasks.lastSavedID"))
            let reopened = TaskBoardStore(repository: repository, defaults: defaults)
            XCTAssertNil(reopened.lastSavedID)
            await store.undoLastSave()
            XCTAssertNil(store.errorMessage)
            XCTAssertTrue(repository.deletedIDs.isEmpty)
        }
    }
    func testUndoAfterReopenRecognizesTaskAlreadyRemovedWithoutError() async {
        await check { store, repository, defaults in
            store.makeDraft("Deleted before restart"); await store.saveDraft()
            repository.values.removeAll()
            let reopened = TaskBoardStore(repository: repository, defaults: defaults)
            await reopened.undoLastSave()
            XCTAssertNil(reopened.lastSavedID)
            XCTAssertNil(reopened.errorMessage)
            XCTAssertTrue(repository.deletedIDs.isEmpty)
        }
    }
    func testFailedRefreshPreservesUndoAndOriginalFetchError() async {
        await check { store, repository, defaults in
            store.makeDraft("Still recoverable"); await store.saveDraft()
            let id = store.lastSavedID
            repository.values.removeAll(); repository.failFetch = true
            await store.refresh()
            XCTAssertEqual(store.lastSavedID, id)
            let reopened = TaskBoardStore(repository: repository, defaults: defaults)
            await reopened.undoLastSave()
            XCTAssertEqual(reopened.lastSavedID, id)
            XCTAssertEqual(reopened.errorMessage, TaskServiceError.fetchFailed.localizedDescription)
            XCTAssertTrue(repository.deletedIDs.isEmpty)
        }
    }
    func testStaleEmptyFetchCannotClearCurrentUndo() async {
        await check { store, repository, defaults in
            store.makeDraft("Keep current Undo"); await store.saveDraft()
            let id = store.lastSavedID
            repository.suspendNextFetch = true
            let stale = Task { await store.refresh() }
            while repository.pendingFetch == nil { await Task.yield() }
            await store.refresh()
            repository.finishFetch(with: [])
            await stale.value
            XCTAssertEqual(store.lastSavedID, id)
            XCTAssertEqual(defaults.string(forKey: "tasks.lastSavedID"), id)
            XCTAssertEqual(store.tasks.count, 1)
        }
    }
    func testUndoSurvivesTaskMovingToAnotherList() async {
        await check { store, repository, _ in
            store.makeDraft("Moved elsewhere"); await store.saveDraft()
            let id = store.lastSavedID
            repository.listValues.append(TaskList(id: "other", title: "Other", account: "Local", isLocal: true, writable: true))
            repository.values[0].listID = "other"
            await store.refresh()
            XCTAssertTrue(store.visibleTasks.isEmpty)
            XCTAssertEqual(store.lastSavedID, id)
        }
    }
    func testAuthoritativeAutomationSnapshotAlsoClearsObsoleteUndo() async throws {
        try await check { store, repository, defaults in
            store.makeDraft("Removed externally"); await store.saveDraft()
            repository.values.removeAll()
            _ = try await store.snapshotForAutomation()
            XCTAssertNil(store.lastSavedID)
            XCTAssertNil(defaults.string(forKey: "tasks.lastSavedID"))
        }
    }
    func testListSummaryChangesImmediatelyWithoutErasingOperationMessage() async {
        await check { store, repository, _ in
            repository.listValues.append(TaskList(id: "work", title: "Work", account: "Local", isLocal: true, writable: true))
            store.makeDraft("Personal task"); await store.saveDraft()
            repository.values.append(ReminderTask(id: "work1", title: "Work task", notes: "", due: nil,
                                                  completed: false, listID: "work", alarms: [], recurring: false))
            await store.refresh()
            await store.moveTask(store.tasks.first { $0.listID == "list" }!, to: .doing)
            let message = store.operationMessage
            XCTAssertEqual(message, "Task moved to Doing.")
            store.selectedListID = "work"
            XCTAssertEqual(store.listSummary, "1 open task in Work.")
            XCTAssertEqual(store.operationMessage, message)
            XCTAssertTrue(store.status.contains("1 open task in Work."))
            XCTAssertFalse(store.status.contains("Test list"))
        }
    }
    func testChoosingDefaultListAfterInitialRefreshUpdatesSummary() async {
        await check { store, _, _ in
            store.selectedListID = ""
            await store.refresh()
            XCTAssertEqual(store.listSummary, "Choose a writable list in Tasks settings.")
            store.selectedListID = "list"
            XCTAssertEqual(store.listSummary, "0 open tasks in Test list.")
        }
    }
}

private final class TaskBoardMemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "HeyNotchTests.tasks.memory")! }
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
    override func synchronize() -> Bool { true }
}

@MainActor
private final class FixtureTaskRepository: TaskRepository {
    var values: [ReminderTask] = []
    var failSave = false
    var failFetch = false
    var suspendNextFetch = false
    var pendingFetch: CheckedContinuation<[ReminderTask], Error>?
    var listValues = [TaskList(id: "list", title: "Test list", account: "Local", isLocal: true, writable: true)]
    var deletedIDs: [String] = []
    private var saved: [UUID: String] = [:]
    func requestAccess() async throws {}
    func lists() throws -> [TaskList] { listValues }
    func fetch() async throws -> [ReminderTask] {
        if failFetch { throw TaskServiceError.fetchFailed }
        if suspendNextFetch {
            suspendNextFetch = false
            return try await withCheckedThrowingContinuation { pendingFetch = $0 }
        }
        return values
    }
    func finishFetch(with result: [ReminderTask]) {
        let continuation = pendingFetch; pendingFetch = nil
        continuation?.resume(returning: result)
    }
    func save(_ draft: TaskDraft) async throws -> String {
        if failSave { throw TaskServiceError.saveFailed }
        let id = draft.reminderID ?? saved[draft.id] ?? UUID().uuidString
        let completed = values.first { $0.id == id }?.completed ?? false
        values.removeAll { $0.id == id }
        values.append(ReminderTask(id: id, title: draft.title, notes: draft.notes, due: draft.due, completed: completed, listID: draft.listID, alarms: [], recurring: false))
        saved[draft.id] = id; return id
    }
    func complete(_ id: String, completed: Bool) throws { values[values.firstIndex { $0.id == id }!].completed = completed }
    func delete(_ id: String) throws { deletedIDs.append(id); values.removeAll { $0.id == id } }
}
