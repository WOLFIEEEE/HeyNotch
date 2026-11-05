import XCTest

@MainActor
final class TaskBoardProjectionTests: XCTestCase {
    private func fixture(_ body: (TaskBoardStore, ProjectionRepository) async -> Void) async {
        let name = "HeyNotchTests.projection." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let repository = ProjectionRepository()
        let store = TaskBoardStore(repository: repository, defaults: defaults)
        store.selectedListID = "list"
        await store.refresh()
        await body(store, repository)
    }

    func testRepeatedColumnAndVisibleReadsPreserveFullValuesAndOriginalSortOrder() async {
        await fixture { store, repository in
            let expected = referenceOrder(repository.values, listID: "list")
            let doing = expected.first { !$0.completed }!
            await store.moveTask(doing, to: .doing)
            for _ in 0..<4 {
                XCTAssertEqual(store.visibleTasks, expected)
                XCTAssertEqual(store.tasks(in: .todo), expected.filter { !$0.completed && $0.id != doing.id })
                XCTAssertEqual(store.tasks(in: .doing), [doing])
                XCTAssertEqual(store.tasks(in: .done), expected.filter(\.completed))
                XCTAssertEqual(store.tallestColumnCount, TaskKanbanColumn.allCases.map { store.tasks(in: $0).count }.max())
            }
            XCTAssertEqual(repository.writeCount, 0)
        }
    }

    func testWarmProjectionTracksSelectionAndLocalProgressWithoutReminderWrites() async {
        await fixture { store, repository in
            let original = store.visibleTasks
            let task = original.first { !$0.completed }!
            _ = store.tasks(in: .todo)
            await store.moveTask(task, to: .doing)
            XCTAssertEqual(store.tasks(in: .doing), [task])
            XCTAssertEqual(store.visibleTasks, original)
            store.selectedListID = "other"
            XCTAssertEqual(store.visibleTasks, referenceOrder(repository.values, listID: "other"))
            XCTAssertTrue(store.tasks(in: .doing).isEmpty)
            store.selectedListID = "list"
            XCTAssertEqual(store.tasks(in: .doing), [task])
            await store.moveTask(task, to: .todo)
            XCTAssertTrue(store.tasks(in: .doing).isEmpty)
            XCTAssertEqual(store.visibleTasks, original)
            XCTAssertEqual(repository.writeCount, 0)
            store.selectedListID = "missing"
            XCTAssertTrue(store.visibleTasks.isEmpty)
            XCTAssertEqual(store.tallestColumnCount, 0)
        }
    }

    func testExternalRefreshReplacesWarmValuesOrderingAndCompletion() async {
        await fixture { store, repository in
            let target = store.visibleTasks.first { !$0.completed }!
            await store.moveTask(target, to: .doing)
            _ = store.tasks(in: .doing)
            let index = repository.values.firstIndex { $0.id == target.id }!
            repository.values[index].title = "An updated title"
            repository.values[index].notes = "Updated note"
            repository.values[index].due = .init(year: 2025, month: 1, day: 1)
            repository.values[index].completed = true
            await store.refresh()
            XCTAssertEqual(store.visibleTasks, referenceOrder(repository.values, listID: "list"))
            XCTAssertEqual(store.tasks(in: .done).first, repository.values[index])
            XCTAssertTrue(store.tasks(in: .doing).isEmpty)
            repository.values[index].listID = "other"
            await store.refresh()
            XCTAssertFalse(store.visibleTasks.contains { $0.id == target.id })
        }
    }

    func testFailedRefreshAndFailedMutationPreserveWarmProjection() async {
        await fixture { store, repository in
            let original = store.visibleTasks
            let task = original.first { !$0.completed }!
            await store.moveTask(task, to: .doing)
            repository.failFetch = true
            repository.values = []
            await store.refresh()
            XCTAssertEqual(store.visibleTasks, original)
            XCTAssertEqual(store.tasks(in: .doing), [task])
            repository.failWrite = true
            await store.moveTask(task, to: .done)
            XCTAssertEqual(store.tasks(in: .doing), [task])
            XCTAssertFalse(store.tasks(in: .done).contains { $0.id == task.id })
            XCTAssertNotNil(store.errorMessage)
        }
    }

    func testSuccessfulCompletionAndDeletionInvalidateBeforeFailedFollowupFetch() async {
        await fixture { store, repository in
            let target = store.visibleTasks.first { !$0.completed }!
            _ = store.tasks(in: .todo)
            repository.failFetch = true
            await store.moveTask(target, to: .done)
            var completed = target; completed.completed = true
            XCTAssertTrue(store.tasks(in: .done).contains(completed))
            XCTAssertFalse(store.tasks(in: .todo).contains { $0.id == target.id })
            await store.delete(completed)
            XCTAssertFalse(store.visibleTasks.contains { $0.id == target.id })
            XCTAssertFalse(store.tasks(in: .done).contains { $0.id == target.id })
            XCTAssertEqual(repository.writeCount, 2)
        }
    }

    func testEditedDraftReordersWarmProjectionAndPreservesReminderFields() async {
        await fixture { store, repository in
            let target = store.visibleTasks.first { !$0.completed }!
            _ = store.tasks(in: .todo)
            store.edit(target)
            store.draft?.title = "A replacement title"
            store.draft?.due = .init(year: 2024, month: 1, day: 1)
            await store.saveDraft()
            let changed = repository.values.first { $0.id == target.id }!
            XCTAssertEqual(store.visibleTasks.first, changed)
            XCTAssertEqual(store.tasks(in: .todo).first, changed)
            XCTAssertEqual(changed.notes, target.notes)
            XCTAssertEqual(changed.alarms, target.alarms)
            XCTAssertEqual(changed.recurring, target.recurring)
        }
    }

    func testChangedCalendarTimeZoneReordersDayOnlyAndFixedTimeTasks() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var losAngeles = utc
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let floating = reminder(id: "floating", due: .init(year: 2026, month: 11, day: 5))
        let fixed = reminder(id: "fixed", due: .init(year: 2026, month: 11, day: 5, hour: 4, minute: 0, timeZoneIdentifier: "UTC"))
        var projection = TaskBoardProjection()
        let source = [floating, fixed]
        XCTAssertEqual(projection.columns(source, listID: "list", doingIDs: [], calendar: utc)[.todo], [floating, fixed])
        XCTAssertEqual(projection.columns(source, listID: "list", doingIDs: [], calendar: losAngeles)[.todo], [fixed, floating])
        XCTAssertEqual(projection.visibleTasks(source, listID: "list", calendar: utc), [floating, fixed])
    }

    func testLocaleChangeKeepsExactValuesAndComparatorSemantics() {
        let source = [reminder(id: "one", title: "Résumé 10"), reminder(id: "two", title: "Résumé 2"), reminder(id: "three", title: "更新")]
        let expected = referenceOrder(source, listID: "list")
        var projection = TaskBoardProjection()
        XCTAssertEqual(projection.visibleTasks(source, listID: "list", locale: Locale(identifier: "en_US")), expected)
        // The cache key follows locale changes, while sorting continues to use
        // Foundation's existing localizedStandardCompare behavior.
        XCTAssertEqual(projection.visibleTasks(source, listID: "list", locale: Locale(identifier: "fr_FR")), expected)
        XCTAssertEqual(projection.columns(source, listID: "list", doingIDs: [], locale: .current)[.todo], expected)
    }
}

private func reminder(id: String, title: String = "Task", due: TaskDue? = nil) -> ReminderTask {
    .init(id: id, title: title, notes: "Keep this note", due: due, completed: false,
          listID: "list", alarms: [.init(absoluteDate: nil, relativeOffset: -300)], recurring: true)
}

private func referenceOrder(_ source: [ReminderTask], listID: String) -> [ReminderTask] {
    source.filter { $0.listID == listID }.sorted {
        let left = $0.due?.date(in: .current) ?? .distantFuture
        let right = $1.due?.date(in: .current) ?? .distantFuture
        return left == right ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : left < right
    }
}

@MainActor
private final class ProjectionRepository: TaskRepository {
    var values: [ReminderTask] = (0..<36).reversed().map { index in
        var value = reminder(id: "task-\(index)", title: ["Résumé", "更新", "Plan", "Café"][index % 4] + " \(index % 12)",
                             due: index % 4 == 0 ? nil : .init(year: 2026, month: 11, day: index % 27 + 1,
                                                             hour: index % 3 == 0 ? nil : index % 12,
                                                             minute: index % 3 == 0 ? nil : 30,
                                                             timeZoneIdentifier: "Asia/Kolkata"))
        value.completed = index % 5 == 0
        value.listID = index % 7 == 0 ? "other" : "list"
        return value
    }
    var failFetch = false
    var failWrite = false
    var writeCount = 0
    func requestAccess() async throws {}
    func lists() throws -> [TaskList] {
        ["list", "other"].map { .init(id: $0, title: $0, account: "Test", isLocal: true, writable: true) }
    }
    func fetch() async throws -> [ReminderTask] {
        if failFetch { throw TaskServiceError.fetchFailed }
        return values
    }
    func save(_ draft: TaskDraft) async throws -> String {
        guard !failWrite, let index = values.firstIndex(where: { $0.id == draft.reminderID }) else { throw TaskServiceError.saveFailed }
        writeCount += 1
        values[index].title = draft.title; values[index].notes = draft.notes
        values[index].due = draft.due; values[index].listID = draft.listID
        return values[index].id
    }
    func complete(_ id: String, completed: Bool) throws {
        guard !failWrite, let index = values.firstIndex(where: { $0.id == id }) else { throw TaskServiceError.saveFailed }
        writeCount += 1; values[index].completed = completed
    }
    func delete(_ id: String) throws {
        guard !failWrite else { throw TaskServiceError.saveFailed }
        writeCount += 1; values.removeAll { $0.id == id }
    }
}
