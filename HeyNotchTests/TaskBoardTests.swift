import XCTest

@MainActor
final class TaskBoardTests: XCTestCase {
    private func check(_ body: (TaskBoardStore, FixtureTaskRepository, UserDefaults) async throws -> Void) async rethrows {
        let name = "HeyNotchTests.tasks.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let repository = FixtureTaskRepository()
        defer { defaults.removePersistentDomain(forName: name) }
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
}

@MainActor
private final class FixtureTaskRepository: TaskRepository {
    var values: [ReminderTask] = []
    var failSave = false
    var deletedIDs: [String] = []
    private var saved: [UUID: String] = [:]
    func requestAccess() async throws {}
    func lists() throws -> [TaskList] { [TaskList(id: "list", title: "Test list", account: "Local", isLocal: true, writable: true)] }
    func fetch() async throws -> [ReminderTask] { values }
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
