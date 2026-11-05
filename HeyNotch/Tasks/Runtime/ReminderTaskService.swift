import EventKit
import Foundation

enum EventStoreProvider {
    static let shared = EKEventStore()
}

@MainActor
private final class ReminderFetch {
    private var continuation: CheckedContinuation<[EKReminder], Error>?
    private var token: Any?
    private var timeout: Task<Void, Never>?
    private let store: EKEventStore
    init(store: EKEventStore) { self.store = store }
    func run() async throws -> [EKReminder] {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                token = store.fetchReminders(matching: store.predicateForReminders(in: nil)) { reminders in
                    Task { @MainActor in
                        if let reminders { self.finish(.success(reminders)) }
                        else { self.finish(.failure(TaskServiceError.fetchFailed)) }
                    }
                }
                timeout = Task {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    self.finish(.failure(TaskServiceError.fetchFailed))
                }
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } }
    }
    private func finish(_ result: Result<[EKReminder], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        if let token {
            if case .failure = result { store.cancelFetchRequest(token) }
            self.token = nil
        }
        continuation.resume(with: result)
    }
}

@MainActor
final class ReminderTaskService: TaskRepository {
    private let store: EKEventStore
    private let defaults: UserDefaults
    private var saves: [String: String]
    private let journalKey = "tasks.saveJournal.v1"
    init(store: EKEventStore = EventStoreProvider.shared, defaults: UserDefaults = .standard) {
        self.store = store; self.defaults = defaults
        saves = defaults.dictionary(forKey: journalKey) as? [String: String] ?? [:]
    }
    var authorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    private func requireAccess() throws { guard authorized else { throw TaskServiceError.permission } }
    func requestAccess() async throws {
        if !authorized { guard try await store.requestFullAccessToReminders() else { throw TaskServiceError.permission } }
    }
    func lists() throws -> [TaskList] {
        try requireAccess()
        return store.calendars(for: .reminder).map {
            TaskList(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title,
                     isLocal: $0.source.sourceType == .local, writable: $0.allowsContentModifications)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    func defaultListID() -> String? { store.defaultCalendarForNewReminders()?.calendarIdentifier }
    func createHeyNotchList() throws -> String {
        try requireAccess()
        if let saved = defaults.string(forKey: "tasks.heyNotchList"), let list = store.calendar(withIdentifier: saved), list.allowsContentModifications { return saved }
        guard let source = store.defaultCalendarForNewReminders()?.source else { throw TaskServiceError.noList }
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == "HeyNotch" && $0.source.sourceIdentifier == source.sourceIdentifier && $0.allowsContentModifications }) {
            defaults.set(existing.calendarIdentifier, forKey: "tasks.heyNotchList"); return existing.calendarIdentifier
        }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = "HeyNotch"; calendar.source = source
        do { try store.saveCalendar(calendar, commit: true) } catch { throw TaskServiceError.saveFailed }
        defaults.set(calendar.calendarIdentifier, forKey: "tasks.heyNotchList")
        return calendar.calendarIdentifier
    }
    func fetch() async throws -> [ReminderTask] {
        try requireAccess()
        return try await ReminderFetch(store: store).run().map(Self.model)
    }
    func save(_ draft: TaskDraft) async throws -> String {
        try requireAccess()
        guard draft.canSave else { throw TaskServiceError.invalidDraft }
        if let due = draft.due {
            guard let date = due.date(in: .current), TaskDue.from(date, hasTime: due.hasTime, calendar: dueCalendar(due)) == due else { throw TaskServiceError.invalidDraft }
        }
        let operation = draft.id.uuidString
        if draft.reminderID == nil, let saved = saves[operation] {
            if saved != "pending" { return saved }
            let existing = try await ReminderFetch(store: store).run().first { $0.url == operationURL(draft.id) }
            if let existing { record(operation, id: existing.calendarItemIdentifier); return existing.calendarItemIdentifier }
            throw TaskServiceError.duplicateUncertain
        }
        guard let list = store.calendar(withIdentifier: draft.listID), list.allowedEntityTypes.contains(.reminder) else { throw TaskServiceError.noList }
        guard list.allowsContentModifications else { throw TaskServiceError.readOnly }
        let reminder: EKReminder
        if let id = draft.reminderID {
            guard let existing = store.calendarItem(withIdentifier: id) as? EKReminder else { throw TaskServiceError.missing }
            guard existing.calendar.allowsContentModifications else { throw TaskServiceError.readOnly }
            reminder = existing
        } else {
            reminder = EKReminder(eventStore: store)
            reminder.url = operationURL(draft.id)
        }
        reminder.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        reminder.notes = draft.notes.isEmpty ? nil : draft.notes
        reminder.calendar = list
        reminder.dueDateComponents = draft.due?.components
        switch draft.alarm {
        case .keep: break
        case .off: reminder.alarms = nil
        case .atDue:
            if let due = draft.due, due.hasTime, let date = due.date(in: .current) { reminder.alarms = [EKAlarm(absoluteDate: date)] }
            else { reminder.alarms = nil }
        }
        if draft.reminderID == nil { record(operation, id: "pending") }
        do { try store.save(reminder, commit: true) }
        catch { throw draft.reminderID == nil ? TaskServiceError.duplicateUncertain : .saveFailed }
        record(operation, id: reminder.calendarItemIdentifier)
        return reminder.calendarItemIdentifier
    }
    func complete(_ id: String, completed: Bool) throws {
        try requireAccess()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw TaskServiceError.missing }
        guard reminder.calendar.allowsContentModifications else { throw TaskServiceError.readOnly }
        reminder.isCompleted = completed
        do { try store.save(reminder, commit: true) } catch { throw TaskServiceError.saveFailed }
    }
    func delete(_ id: String) throws {
        try requireAccess()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw TaskServiceError.missing }
        guard reminder.calendar.allowsContentModifications else { throw TaskServiceError.readOnly }
        do { try store.remove(reminder, commit: true) } catch { throw TaskServiceError.saveFailed }
    }
    func identifierForOperation(_ operation: UUID) async throws -> String? {
        try requireAccess()
        if let saved = saves[operation.uuidString], saved != "pending" { return saved }
        return try await ReminderFetch(store: store).run().first { $0.url == TaskLink.url(operation) }?.calendarItemIdentifier
    }
    private func operationURL(_ id: UUID) -> URL { TaskLink.url(id) }
    private func record(_ operation: String, id: String) {
        saves[operation] = id
        // Keep uncertain saves until explicitly resolved; retain a bounded completed history.
        if saves.count > 256, let key = saves.first(where: { $0.key != operation && $0.value != "pending" })?.key { saves.removeValue(forKey: key) }
        defaults.set(saves, forKey: journalKey)
    }
    private func dueCalendar(_ due: TaskDue) -> Calendar {
        var calendar = Calendar.current
        if let zone = due.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) { calendar.timeZone = zone }
        return calendar
    }
    private static func model(_ reminder: EKReminder) -> ReminderTask {
        var due: TaskDue?
        if let value = reminder.dueDateComponents, let year = value.year, let month = value.month, let day = value.day {
            due = TaskDue(year: year, month: month, day: day, hour: value.hour, minute: value.hour == nil ? nil : value.minute ?? 0,
                          timeZoneIdentifier: value.hour == nil ? nil : (value.timeZone ?? .current).identifier)
        }
        return ReminderTask(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Untitled task", notes: reminder.notes ?? "",
                            due: due, completed: reminder.isCompleted, listID: reminder.calendar.calendarIdentifier,
                            alarms: (reminder.alarms ?? []).map { TaskAlarm(absoluteDate: $0.absoluteDate, relativeOffset: $0.relativeOffset) },
                            recurring: reminder.hasRecurrenceRules)
    }
}
