import Combine
import Foundation

@MainActor
class TaskBoardStore: ObservableObject {
    let repository: any TaskRepository
    let defaults: UserDefaults
    @Published private(set) var tasks: [ReminderTask] = [] {
        didSet { projection.invalidateTasks() }
    }
    @Published private(set) var lists: [TaskList] = []
    @Published var draft: TaskDraft?
    @Published private(set) var status = "Connect Apple Reminders to see your tasks."
    @Published private(set) var errorMessage: String?
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var lastSavedID: String?
    @Published private(set) var pendingTaskIDs: Set<String> = []
    @Published private var doingIDs: Set<String> {
        didSet { projection.invalidateColumns() }
    }
    @Published var selectedListID: String { didSet { defaults.set(selectedListID, forKey: "tasks.selectedList") } }
    private var projection = TaskBoardProjection()
    private var refreshID = UUID()
    private var taskWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    static let doingPreferenceKey = "tasks.kanban.doingIDs.v1"

    init(repository: any TaskRepository, defaults: UserDefaults = .standard) {
        self.repository = repository; self.defaults = defaults
        selectedListID = defaults.string(forKey: "tasks.selectedList") ?? ""
        lastSavedID = defaults.string(forKey: "tasks.lastSavedID")
        doingIDs = Set(defaults.stringArray(forKey: Self.doingPreferenceKey) ?? []).filter { !$0.isEmpty }
    }
    var selectedList: TaskList? { lists.first { $0.id == selectedListID && $0.writable } }
    var visibleTasks: [ReminderTask] {
        projection.visibleTasks(tasks, listID: selectedListID)
    }
    func column(for task: ReminderTask) -> TaskKanbanColumn {
        let current = tasks.first(where: { $0.id == task.id }) ?? task
        return columnForCanonicalTask(current)
    }
    /// Use only for records freshly read from the repository, not caller-supplied payloads.
    func columnForCanonicalTask(_ task: ReminderTask) -> TaskKanbanColumn {
        task.completed ? .done : (doingIDs.contains(task.id) ? .doing : .todo)
    }
    func tasks(in column: TaskKanbanColumn) -> [ReminderTask] {
        projection.columns(tasks, listID: selectedListID, doingIDs: doingIDs)[column] ?? []
    }
    var tallestColumnCount: Int {
        projection.columns(tasks, listID: selectedListID, doingIDs: doingIDs).values.map(\.count).max() ?? 0
    }
    func canMoveTask(_ task: ReminderTask) -> Bool {
        guard !pendingTaskIDs.contains(task.id), let current = tasks.first(where: { $0.id == task.id }) else { return false }
        return current.listID == selectedListID && lists.contains { $0.id == current.listID && $0.writable }
    }
    /// Kanban progress never rewrites reminder dates, notes, alarms or lists.
    /// Only Done maps to EventKit completion; Doing stays on this Mac.
    func moveTask(_ task: ReminderTask, to column: TaskKanbanColumn) async {
        await beginTaskOperation(task.id)
        defer { endTaskOperation(task.id) }
        guard !Task.isCancelled else { return }
        do {
            let current = try mutableTask(id: task.id, requireCurrentList: true)
            let completed = column == .done
            let requiresReminderWrite = current.completed != completed
            if requiresReminderWrite {
                try repository.complete(current.id, completed: completed)
                invalidateOlderRefresh()
                if let index = tasks.firstIndex(where: { $0.id == current.id }) { tasks[index].completed = completed }
            }
            // Update local progress only after the reminder write succeeds.
            updateDoing(current.id, doing: column == .doing)
            if requiresReminderWrite { await refresh() }
            else { errorMessage = nil }
            if errorMessage == nil { status = "Task moved to \(column.title)." }
        } catch { report(error) }
    }
    func connect() async {
        do { try await repository.requestAccess(); await refresh() }
        catch { report(error) }
    }
    func refresh() async {
        let id = UUID(); refreshID = id; loading = true
        defer { if refreshID == id { loading = false } }
        do {
            let foundLists = try repository.lists()
            let foundTasks = try await repository.fetch()
            guard refreshID == id else { return }
            lists = foundLists; tasks = foundTasks
            // fetch() returns all reminders, not only the selected list. Never
            // clean local progress from a partial/failed/stale refresh.
            let active = Set(foundTasks.filter { !$0.completed }.map(\.id))
            let retained = doingIDs.intersection(active)
            if retained != doingIDs { doingIDs = retained; persistDoing() }
            errorMessage = nil
            if selectedList == nil { status = "Choose a writable list in Tasks settings." }
            else { status = "\(visibleTasks.filter { !$0.completed }.count) open tasks in \(selectedList!.title)." }
        } catch { if refreshID == id { report(error) } }
    }
    func makeDraft(_ text: String = "", now: Date = Date()) {
        var value = TaskDateParser(now: now).parse(text)
        value.listID = selectedListID
        value.alarm = defaults.object(forKey: "tasks.notifyAtDue") as? Bool ?? true ? .atDue : .off
        draft = value
    }
    func edit(_ task: ReminderTask) {
        draft = TaskDraft(reminderID: task.id, title: task.title, notes: task.notes, due: task.due, listID: task.listID, alarm: .keep)
    }
    func saveDraft() async {
        guard !saving, let value = draft else { return }
        guard value.canSave else { report(TaskServiceError.invalidDraft); return }
        saving = true; defer { saving = false }
        if let id = value.reminderID { await beginTaskOperation(id) }
        defer { if let id = value.reminderID { endTaskOperation(id) } }
        guard !Task.isCancelled else { return }
        do {
            if let id = value.reminderID {
                // An edit queued behind deletion must not recreate the reminder.
                _ = try mutableTask(id: id, requireCurrentList: false)
            }
            let id = try await repository.save(value)
            invalidateOlderRefresh()
            if value.reminderID == nil { lastSavedID = id; defaults.set(id, forKey: "tasks.lastSavedID") }
            await refresh()
            if draft?.id == value.id { draft = nil }
            status = value.reminderID == nil ? "Task saved to Reminders. Undo is available below." : "Task updated."
        } catch { report(error) }
    }
    func setCompleted(_ task: ReminderTask, _ completed: Bool) async {
        await moveTask(task, to: completed ? .done : .todo)
    }
    func delete(_ task: ReminderTask) async {
        await beginTaskOperation(task.id)
        defer { endTaskOperation(task.id) }
        guard !Task.isCancelled else { return }
        do {
            let current = try mutableTask(id: task.id, requireCurrentList: true)
            try repository.delete(current.id)
            invalidateOlderRefresh()
            updateDoing(current.id, doing: false)
            tasks.removeAll { $0.id == current.id }
            if lastSavedID == task.id { lastSavedID = nil; defaults.removeObject(forKey: "tasks.lastSavedID") }
            await refresh(); status = "Task deleted."
        } catch { report(error) }
    }
    func undoLastSave() async {
        guard let id = lastSavedID, !saving else { return }
        saving = true; defer { saving = false }
        await beginTaskOperation(id)
        defer { endTaskOperation(id) }
        guard !Task.isCancelled else { return }
        do {
            if !tasks.contains(where: { $0.id == id }) { await refresh() }
            _ = try mutableTask(id: id, requireCurrentList: false)
            try repository.delete(id)
            invalidateOlderRefresh()
            updateDoing(id, doing: false)
            tasks.removeAll { $0.id == id }
            lastSavedID = nil; defaults.removeObject(forKey: "tasks.lastSavedID")
            await refresh(); status = "The last task created by HeyNotch was removed."
        } catch { report(error) }
    }
    func report(_ error: Error) {
        errorMessage = (error as? TaskServiceError)?.localizedDescription ?? (error as? ProcessingError)?.localizedDescription ?? "This task operation could not finish. Your draft is still available."
    }
    func clearError() { errorMessage = nil }

    /// Automation shares the same FIFO as edits, completion, deletion and undo.
    /// The caller re-reads and validates its revision after this gate is acquired.
    func withTaskOperation<T>(id: String, operation: @MainActor () async throws -> T) async throws -> T {
        await beginTaskOperation(id)
        defer { endTaskOperation(id) }
        try Task.checkCancellation()
        return try await operation()
    }

    /// Returns errors to the command caller without replacing an editor draft or list selection.
    /// A newer mutation/refresh prevents an older full fetch from replacing board state.
    func snapshotForAutomation() async throws -> (lists: [TaskList], tasks: [ReminderTask]) {
        invalidateOlderRefresh()
        let id = refreshID
        let foundLists = try repository.lists()
        let foundTasks = try await repository.fetch()
        if refreshID == id {
            lists = foundLists; tasks = foundTasks
            let active = Set(foundTasks.filter { !$0.completed }.map(\.id))
            let retained = doingIDs.intersection(active)
            if retained != doingIDs { doingIDs = retained; persistDoing() }
        }
        return (foundLists, foundTasks)
    }

    /// Keep a committed change visible even if its subsequent verification fetch fails.
    /// Flush local progress before automation acknowledges a durable move.
    func recordAutomationChange(_ task: ReminderTask, doing: Bool? = nil) throws {
        invalidateOlderRefresh()
        if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task }
        else { tasks.append(task) }
        if let doing {
            updateDoing(task.id, doing: doing && !task.completed)
            guard defaults.synchronize() else { throw TaskServiceError.saveFailed }
        }
    }
    private func mutableTask(id: String, requireCurrentList: Bool) throws -> ReminderTask {
        guard let current = tasks.first(where: { $0.id == id }), !requireCurrentList || current.listID == selectedListID else { throw TaskServiceError.missing }
        guard let list = lists.first(where: { $0.id == current.listID }) else { throw TaskServiceError.noList }
        guard list.writable else { throw TaskServiceError.readOnly }
        return current
    }
    private func updateDoing(_ id: String, doing: Bool) {
        let before = doingIDs
        if doing { doingIDs.insert(id) } else { doingIDs.remove(id) }
        if before != doingIDs { persistDoing() }
    }
    private func persistDoing() { defaults.set(doingIDs.sorted(), forKey: Self.doingPreferenceKey) }
    private func invalidateOlderRefresh() {
        refreshID = UUID(); loading = false
    }
    private func beginTaskOperation(_ id: String) async {
        if pendingTaskIDs.contains(id) {
            await withCheckedContinuation { taskWaiters[id, default: []].append($0) }
        } else { pendingTaskIDs.insert(id) }
    }
    private func endTaskOperation(_ id: String) {
        if var waiters = taskWaiters[id], !waiters.isEmpty {
            let next = waiters.removeFirst(); taskWaiters[id] = waiters.isEmpty ? nil : waiters
            next.resume()
        } else { pendingTaskIDs.remove(id); taskWaiters[id] = nil }
    }
}

/// A selected-list snapshot shared by lane counts, cards and notch sizing. Rebuild
/// only when reminder data, local progress or the sorting environment changes.
/// Calendar conversion happens once per reminder, rather than twice per sort comparison.
struct TaskBoardProjection {
    private struct Ordered {
        let listID: String
        let calendar: Calendar
        let locale: Locale
        let tasks: [ReminderTask]
    }
    private var ordered: Ordered?
    private var partitioned: [TaskKanbanColumn: [ReminderTask]]?

    mutating func invalidateTasks() { ordered = nil; partitioned = nil }
    mutating func invalidateColumns() { partitioned = nil }

    mutating func visibleTasks(_ source: [ReminderTask], listID: String,
                               calendar: Calendar = .current, locale: Locale = .current) -> [ReminderTask] {
        if let ordered, ordered.listID == listID, ordered.calendar == calendar, ordered.locale == locale {
            return ordered.tasks
        }
        let selected = source.filter { $0.listID == listID }
        let dated: [(task: ReminderTask, date: Date)] = selected.map {
            (task: $0, date: $0.due?.date(in: calendar) ?? .distantFuture)
        }
        let sorted = dated.sorted { left, right in
            left.date == right.date
                ? left.task.title.localizedStandardCompare(right.task.title) == .orderedAscending
                : left.date < right.date
        }.map(\.task)
        ordered = Ordered(listID: listID, calendar: calendar, locale: locale, tasks: sorted)
        partitioned = nil
        return sorted
    }

    mutating func columns(_ source: [ReminderTask], listID: String, doingIDs: Set<String>,
                          calendar: Calendar = .current, locale: Locale = .current) -> [TaskKanbanColumn: [ReminderTask]] {
        // Validate environment/list even when the partition already exists.
        let visible = visibleTasks(source, listID: listID, calendar: calendar, locale: locale)
        if let partitioned { return partitioned }
        var result: [TaskKanbanColumn: [ReminderTask]] = [:]
        for task in visible {
            let column: TaskKanbanColumn = task.completed ? .done : (doingIDs.contains(task.id) ? .doing : .todo)
            result[column, default: []].append(task)
        }
        partitioned = result
        return result
    }
}
