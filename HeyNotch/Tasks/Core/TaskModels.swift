import Foundation

struct TaskDue: Codable, Equatable, Sendable {
    var year: Int
    var month: Int
    var day: Int
    var hour: Int?
    var minute: Int?
    var timeZoneIdentifier: String?
    var hasTime: Bool { hour != nil }
    var components: DateComponents {
        var value = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        if hasTime { value.timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current }
        return value
    }
    func date(in calendar: Calendar) -> Date? {
        var calendar = calendar
        if hasTime, let zone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) { calendar.timeZone = zone }
        return calendar.date(from: components)
    }
    static func from(_ date: Date, hasTime: Bool, calendar: Calendar) -> Self {
        let value = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return Self(year: value.year!, month: value.month!, day: value.day!, hour: hasTime ? value.hour : nil,
                    minute: hasTime ? value.minute : nil, timeZoneIdentifier: hasTime ? calendar.timeZone.identifier : nil)
    }
}

struct TaskList: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let account: String
    let isLocal: Bool
    let writable: Bool
}

struct TaskAlarm: Equatable, Sendable {
    let absoluteDate: Date?
    let relativeOffset: TimeInterval
}

struct ReminderTask: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var notes: String
    var due: TaskDue?
    var completed: Bool
    var listID: String
    var alarms: [TaskAlarm]
    var recurring: Bool
}

enum TaskAlarmChoice: String, Codable, CaseIterable, Sendable { case off = "No notification", atDue = "At the due time", keep = "Keep existing notifications" }
enum TaskDraftOrigin: String, Codable, Sendable { case meeting }

struct TaskDraft: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var reminderID: String?
    var title = ""
    var notes = ""
    var due: TaskDue?
    var listID = ""
    var alarm: TaskAlarmChoice = .off
    var reviewReasons: [String] = []
    var sourceText = ""
    var reviewAcknowledged = false
    // Optional for decoding drafts created before meeting-derived tasks existed.
    var origin: TaskDraftOrigin?
    var needsReview: Bool { !reviewReasons.isEmpty && !reviewAcknowledged }
    var permitsCloudAssistance: Bool { origin != .meeting }
    var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.utf8.count <= 4096 && !needsReview }
}

enum TaskSection: String, CaseIterable, Identifiable {
    case overdue = "Overdue", today = "Today", upcoming = "Upcoming", undated = "No date", completed = "Completed"
    var id: String { rawValue }
    static func section(for task: ReminderTask, now: Date, calendar: Calendar) -> Self {
        if task.completed { return .completed }
        guard let due = task.due, let date = due.date(in: calendar) else { return .undated }
        if date < (due.hasTime ? now : calendar.startOfDay(for: now)) { return .overdue }
        return calendar.isDate(date, inSameDayAs: now) ? .today : .upcoming
    }
}

enum TaskServiceError: Error, LocalizedError, Equatable {
    case permission, noList, readOnly, missing, saveFailed, fetchFailed, duplicateUncertain, invalidDraft
    var errorDescription: String? {
        switch self {
        case .permission: return "Allow Reminders access for HeyNotch to view and save tasks."
        case .noList: return "Choose a writable Reminders list in Tasks settings."
        case .readOnly: return "This Reminders list is read-only. Choose another list."
        case .missing: return "This reminder was removed or moved. Refresh the task list."
        case .saveFailed: return "Reminders could not save this change. Your draft is still available."
        case .fetchFailed: return "Reminders could not load your tasks. Try refreshing."
        case .duplicateUncertain: return "This save may already have completed. Refresh Reminders before creating another copy."
        case .invalidDraft: return "Add a title and review the proposed date before saving."
        }
    }
}

enum TaskLink {
    static func url(_ operation: UUID) -> URL { URL(string: "heynotch://task/\(operation.uuidString)")! }
    static func operation(in url: URL) -> UUID? {
        guard url.scheme == "heynotch", url.host == "task", url.query == nil, url.fragment == nil,
              url.pathComponents.count == 2 else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}

@MainActor
protocol TaskRepository: AnyObject {
    func requestAccess() async throws
    func lists() throws -> [TaskList]
    func fetch() async throws -> [ReminderTask]
    func save(_ draft: TaskDraft) async throws -> String
    func complete(_ id: String, completed: Bool) throws
    func delete(_ id: String) throws
}
