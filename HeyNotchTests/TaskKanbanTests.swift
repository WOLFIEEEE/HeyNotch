import XCTest

@MainActor
final class TaskKanbanTests: XCTestCase {
    private func fixture(_ body: (TaskBoardStore, KanbanRepository, UserDefaults) async throws -> Void) async rethrows {
        let name = "HeyNotchTests.kanban." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let repository = KanbanRepository()
        let store = TaskBoardStore(repository: repository, defaults: defaults)
        store.selectedListID = "list"; await store.refresh()
        try await body(store, repository, defaults)
    }
    func testTodoDoingRoundTripUsesOnlyLocalProgressAndSurvivesRelaunch() async {
        await fixture { store, repository, defaults in
            let original = repository.values[0]
            await store.moveTask(original, to: .doing)
            XCTAssertEqual(store.column(for: original), .doing)
            XCTAssertEqual(repository.values[0], original)
            XCTAssertTrue(repository.completions.isEmpty); XCTAssertEqual(repository.saveCount, 0)
            let reopened = TaskBoardStore(repository: repository, defaults: defaults); await reopened.refresh()
            XCTAssertEqual(reopened.column(for: original), .doing)
            await reopened.moveTask(original, to: .todo)
            XCTAssertEqual(reopened.column(for: original), .todo)
            XCTAssertTrue(repository.completions.isEmpty)
            XCTAssertEqual(defaults.stringArray(forKey: TaskBoardStore.doingPreferenceKey), [])
        }
    }
    func testDoneOnlyChangesCompletionAndUncompleteToDoingPreservesAllOtherFields() async {
        await fixture { store, repository, _ in
            let original = repository.values[0]
            await store.moveTask(original, to: .done)
            var expected = original; expected.completed = true
            XCTAssertEqual(repository.values[0], expected)
            XCTAssertEqual(store.column(for: original), .done)
            await store.moveTask(original, to: .doing)
            XCTAssertEqual(repository.values[0], original)
            XCTAssertEqual(store.column(for: original), .doing)
            XCTAssertEqual(repository.completions.map(\.completed), [true, false])
            XCTAssertEqual(repository.saveCount, 0)
        }
    }
    func testFailedCompletionPreservesDoingAndReminderFields() async {
        await fixture { store, repository, defaults in
            let original = repository.values[0]
            await store.moveTask(original, to: .doing)
            repository.failComplete = true
            await store.moveTask(original, to: .done)
            XCTAssertEqual(store.column(for: original), .doing)
            XCTAssertEqual(repository.values[0], original)
            XCTAssertEqual(defaults.stringArray(forKey: TaskBoardStore.doingPreferenceKey), [original.id])
            XCTAssertNotNil(store.errorMessage); XCTAssertTrue(store.pendingTaskIDs.isEmpty)
        }
    }
    func testFailedUncompleteDoesNotInventLocalDoingState() async {
        await fixture { store, repository, defaults in
            repository.values[0].completed = true; await store.refresh()
            repository.failComplete = true
            await store.moveTask(repository.values[0], to: .doing)
            XCTAssertEqual(store.column(for: repository.values[0]), .done)
            XCTAssertFalse((defaults.stringArray(forKey: TaskBoardStore.doingPreferenceKey) ?? []).contains(repository.values[0].id))
            XCTAssertNotNil(store.errorMessage)
        }
    }
    func testExternalCompletionOverridesDoingAndReopenedTaskReturnsToTodo() async {
        await fixture { store, repository, defaults in
            let original = repository.values[0]
            await store.moveTask(original, to: .doing)
            repository.values[0].completed = true; await store.refresh()
            XCTAssertEqual(store.column(for: original), .done)
            XCTAssertEqual(defaults.stringArray(forKey: TaskBoardStore.doingPreferenceKey), [])
            repository.values[0].completed = false; await store.refresh()
            XCTAssertEqual(store.column(for: original), .todo)
        }
    }
    func testFailedFetchDoesNotDiscardDoingButSuccessfulFullFetchPrunesMissingIDs() async {
        await fixture { store, repository, defaults in
            let original = repository.values[0]
            await store.moveTask(original, to: .doing)
            repository.values = []; repository.failFetch = true; await store.refresh()
            XCTAssertEqual(store.column(for: original), .doing)
            XCTAssertEqual(defaults.stringArray(forKey: TaskBoardStore.doingPreferenceKey), [original.id])
            repository.failFetch = false; await store.refresh()
            XCTAssertEqual(defaults.stringArray(forKey: TaskBoardStore.doingPreferenceKey), [])
        }
    }
    func testMovingRejectsUnknownOtherListAndReadOnlyTasks() async {
        await fixture { store, repository, _ in
            var unknown = repository.values[0]; unknown = ReminderTask(id: "unknown", title: unknown.title, notes: unknown.notes, due: unknown.due, completed: false, listID: "list", alarms: [], recurring: false)
            XCTAssertFalse(store.canMoveTask(unknown)); await store.moveTask(unknown, to: .done)
            XCTAssertFalse(store.canMoveTask(repository.values[1])); await store.moveTask(repository.values[1], to: .done)
            repository.availableLists[0] = TaskList(id: "list", title: "Shared", account: "Local", isLocal: true, writable: false)
            await store.refresh(); XCTAssertFalse(store.canMoveTask(repository.values[0]))
            await store.moveTask(repository.values[0], to: .doing)
            XCTAssertTrue(repository.completions.isEmpty); XCTAssertEqual(store.column(for: repository.values[0]), .todo)
        }
    }
    func testPayloadFieldsCannotMoveTaskBetweenListsOrChangeItsContents() async {
        await fixture { store, repository, _ in
            let original = repository.values[0]
            var stale = original; stale.listID = "other"; stale.title = "altered"; stale.notes = "altered"; stale.due = nil
            await store.moveTask(stale, to: .done)
            var expected = original; expected.completed = true
            XCTAssertEqual(repository.values[0], expected)
        }
    }
    func testColumnsContainOnlyCurrentListAndKeepDueDateOrdering() async {
        await fixture { store, repository, _ in
            let original = repository.values[0]
            await store.moveTask(original, to: .doing)
            XCTAssertEqual(store.tasks(in: .doing).map(\.id), [original.id])
            XCTAssertTrue(store.tasks(in: .todo).isEmpty)
            store.selectedListID = "other"
            XCTAssertEqual(store.tasks(in: .todo).map(\.id), [repository.values[1].id])
            XCTAssertTrue(store.tasks(in: .doing).isEmpty)
            store.selectedListID = "list"; await store.refresh()
            XCTAssertEqual(store.tasks(in: .doing).map(\.id), [original.id])
        }
    }
    func testConflictingMovesAreSerializedAndPendingIsVisible() async {
        await fixture { store, repository, _ in
            let original = repository.values[0]
            repository.holdNextFetch = true
            let first = Task { await store.moveTask(original, to: .done) }
            for _ in 0..<100 where repository.fetchContinuation == nil { await Task.yield() }
            XCTAssertNotNil(repository.fetchContinuation)
            XCTAssertTrue(store.pendingTaskIDs.contains(original.id)); XCTAssertFalse(store.canMoveTask(original))
            let second = Task { await store.moveTask(original, to: .doing) }
            for _ in 0..<5 { await Task.yield() }
            XCTAssertEqual(repository.completions.map(\.completed), [true])
            repository.releaseFetch()
            await first.value; await second.value
            XCTAssertEqual(repository.completions.map(\.completed), [true, false])
            XCTAssertEqual(store.column(for: original), .doing); XCTAssertTrue(store.pendingTaskIDs.isEmpty)
        }
    }
    func testCancelledWaitingMoveDoesNotWriteAndReleasesPendingState() async {
        await fixture { store, repository, _ in
            let original = repository.values[0]; repository.holdNextFetch = true
            let first = Task { await store.moveTask(original, to: .done) }
            for _ in 0..<100 where repository.fetchContinuation == nil { await Task.yield() }
            let cancelled = Task { await store.moveTask(original, to: .doing) }
            await Task.yield(); cancelled.cancel(); repository.releaseFetch()
            await first.value; await cancelled.value
            XCTAssertEqual(repository.completions.map(\.completed), [true])
            XCTAssertEqual(store.column(for: original), .done); XCTAssertTrue(store.pendingTaskIDs.isEmpty)
        }
    }
    func testDeleteQueuedBehindMoveCannotRaceTheReminderMutation() async {
        await fixture { store, repository, _ in
            let original = repository.values[0]; repository.holdNextFetch = true
            let first = Task { await store.moveTask(original, to: .done) }
            for _ in 0..<100 where repository.fetchContinuation == nil { await Task.yield() }
            let deletion = Task { await store.delete(original) }
            await Task.yield(); XCTAssertTrue(repository.deletedIDs.isEmpty)
            repository.releaseFetch(); await first.value; await deletion.value
            XCTAssertEqual(repository.deletedIDs, [original.id]); XCTAssertFalse(store.tasks.contains { $0.id == original.id })
            XCTAssertTrue(store.pendingTaskIDs.isEmpty)
        }
    }
    func testSuccessfulReminderWriteStillUpdatesColumnWhenRefreshFails() async {
        await fixture { store, repository, _ in
            let original = repository.values[0]; repository.failFetch = true
            await store.moveTask(original, to: .done)
            XCTAssertEqual(store.column(for: original), .done)
            XCTAssertNotNil(store.errorMessage); XCTAssertTrue(store.pendingTaskIDs.isEmpty)
        }
    }
    func testOlderFetchCannotOverwriteACompletedToDoingMove() async {
        await fixture { store, repository, _ in
            repository.values[0].completed = true; await store.refresh()
            let original = repository.values[0]; repository.holdNextFetch = true
            let oldRefresh = Task { await store.refresh() }
            for _ in 0..<100 where repository.fetchContinuation == nil { await Task.yield() }
            await store.moveTask(original, to: .doing)
            repository.releaseFetch(); await oldRefresh.value
            XCTAssertEqual(store.column(for: original), .doing)
            XCTAssertFalse(store.tasks.first { $0.id == original.id }!.completed)
        }
    }
    func testEditQueuedBehindDeletionKeepsDraftAndCannotRecreateReminder() async {
        await fixture { store, repository, _ in
            let original = repository.values[0]; store.edit(original); store.draft?.title = "Edited title"
            repository.holdNextFetch = true
            let deletion = Task { await store.delete(original) }
            for _ in 0..<100 where repository.fetchContinuation == nil { await Task.yield() }
            let edit = Task { await store.saveDraft() }
            await Task.yield(); XCTAssertEqual(repository.saveCount, 0)
            repository.releaseFetch(); await deletion.value; await edit.value
            XCTAssertEqual(repository.saveCount, 0)
            XCTAssertEqual(store.draft?.title, "Edited title"); XCTAssertNotNil(store.errorMessage)
            XCTAssertTrue(store.pendingTaskIDs.isEmpty)
        }
    }
}

@MainActor
private final class KanbanRepository: TaskRepository {
    struct Completion { let id: String; let completed: Bool }
    var values: [ReminderTask] = [
        .init(id: "first", title: "Design review", notes: "Keep these notes", due: .init(year: 2026, month: 11, day: 10, hour: 10, minute: 30, timeZoneIdentifier: "Asia/Kolkata"), completed: false, listID: "list", alarms: [.init(absoluteDate: nil, relativeOffset: -300)], recurring: true),
        .init(id: "second", title: "Other list task", notes: "", due: nil, completed: false, listID: "other", alarms: [], recurring: false)
    ]
    var availableLists = [TaskList(id: "list", title: "Tasks", account: "Local", isLocal: true, writable: true), TaskList(id: "other", title: "Other", account: "Local", isLocal: true, writable: true)]
    var completions: [Completion] = []
    var deletedIDs: [String] = []
    var saveCount = 0
    var failComplete = false
    var failFetch = false
    var holdNextFetch = false
    var fetchContinuation: CheckedContinuation<Void, Never>?
    func requestAccess() async throws {}
    func lists() throws -> [TaskList] { availableLists }
    func fetch() async throws -> [ReminderTask] {
        if failFetch { throw TaskServiceError.fetchFailed }
        let snapshot = values
        if holdNextFetch {
            holdNextFetch = false
            await withCheckedContinuation { fetchContinuation = $0 }
        }
        return snapshot
    }
    func releaseFetch() { fetchContinuation?.resume(); fetchContinuation = nil }
    func save(_ draft: TaskDraft) async throws -> String { saveCount += 1; throw TaskServiceError.saveFailed }
    func complete(_ id: String, completed: Bool) throws {
        if failComplete { throw TaskServiceError.saveFailed }
        guard let index = values.firstIndex(where: { $0.id == id }) else { throw TaskServiceError.missing }
        completions.append(.init(id: id, completed: completed)); values[index].completed = completed
    }
    func delete(_ id: String) throws { deletedIDs.append(id); values.removeAll { $0.id == id } }
}
