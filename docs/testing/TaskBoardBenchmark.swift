import Foundation

// Synthetic, read-only task-store benchmark. No EventKit or AppKit linkage.
// Compile together with the actual task model/store files using build.sh.

@MainActor
private final class SyntheticRepository: TaskRepository {
    let records: [ReminderTask]
    init(_ records: [ReminderTask]) { self.records = records }
    func requestAccess() async throws {}
    func lists() throws -> [TaskList] {
        (0..<4).map { TaskList(id: "list-\($0)", title: "Synthetic list \($0)", account: "Fixture", isLocal: true, writable: true) }
    }
    func fetch() async throws -> [ReminderTask] { records }
    func save(_ draft: TaskDraft) async throws -> String { fatalError("Benchmark must never save reminders") }
    func complete(_ id: String, completed: Bool) throws { fatalError("Benchmark must never write reminders") }
    func delete(_ id: String) throws { fatalError("Benchmark must never delete reminders") }
}

private struct Fixture {
    let tasks: [ReminderTask]
    let doing: Set<String>

    init(count: Int) {
        let titles = ["Review design", "Plan sprint", "Call Anaïs", "更新文档", "Send invoice", "Buy groceries", "Résumé review", "Read chapter", "Prepare café notes", "Finish test"]
        var values: [ReminderTask] = []
        var doing = Set<String>()
        for index in 0..<count {
            let due: TaskDue?
            switch index % 4 {
            case 0: due = nil
            case 1: due = TaskDue(year: 2026, month: 11, day: index % 27 + 1)
            default: due = TaskDue(year: 2026, month: 11, day: index % 27 + 1,
                                  hour: index % 12 + 7, minute: (index % 4) * 15,
                                  timeZoneIdentifier: index % 2 == 0 ? "Asia/Kolkata" : "America/Los_Angeles")
            }
            let id = "synthetic-\(index)"
            let completed = index % 10 < 4
            if !completed, index % 3 == 0 { doing.insert(id) }
            // 60% in the active list, 40% spread over three other lists.
            let list = index % 10 < 6 ? 0 : 1 + index % 3
            values.append(ReminderTask(id: id, title: "\(titles[index % titles.count]) \((index * 17) % 211)",
                                       notes: "Synthetic note \(index). No personal information.", due: due,
                                       completed: completed, listID: "list-\(list)",
                                       alarms: due == nil ? [] : [TaskAlarm(absoluteDate: nil, relativeOffset: 0)],
                                       recurring: index % 13 == 0))
        }
        // Deterministic shuffle exercises actual comparison sorting, not an already sorted fixture.
        var seed: UInt64 = 0xC0FFEE
        if values.count > 1 {
            for index in stride(from: values.count - 1, through: 1, by: -1) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                values.swapAt(index, Int(seed % UInt64(index + 1)))
            }
        }
        self.tasks = values; self.doing = doing
    }
}

// Hypothesis only: local prototype, not production implementation. Cache a sorted
// projection once per task/list/calendar/locale revision, partition after sorting.
@MainActor
private final class ProjectionPrototype {
    let tasks: [ReminderTask]
    let doing: Set<String>
    let listID: String
    private var cached: [TaskKanbanColumn: [ReminderTask]]?
    private var calendar: Calendar?
    private var locale: Locale?

    init(tasks: [ReminderTask], doing: Set<String>, listID: String) {
        self.tasks = tasks; self.doing = doing; self.listID = listID
    }
    func invalidate() { cached = nil }
    func tasks(in column: TaskKanbanColumn) -> [ReminderTask] {
        let currentCalendar = Calendar.current
        let currentLocale = Locale.current
        if let cached, currentCalendar == calendar, currentLocale == locale { return cached[column] ?? [] }
        let selected = tasks.filter { $0.listID == listID }
        let dated: [(task: ReminderTask, date: Date)] = selected.map { (task: $0, date: $0.due?.date(in: currentCalendar) ?? Date.distantFuture) }
        let ordered = dated.sorted { left, right in
                left.date == right.date
                    ? left.task.title.localizedStandardCompare(right.task.title) == .orderedAscending
                    : left.date < right.date
            }
        var columns: [TaskKanbanColumn: [ReminderTask]] = [:]
        for item in ordered {
            let column: TaskKanbanColumn = item.task.completed ? .done : doing.contains(item.task.id) ? .doing : .todo
            columns[column, default: []].append(item.task)
        }
        cached = columns; calendar = currentCalendar; locale = currentLocale
        return columns[column] ?? []
    }
}

@MainActor
private enum Harness {
    static var checksum = 0
    @inline(never) static func consume(_ tasks: [ReminderTask]) {
        checksum &+= tasks.count &+ (tasks.first?.id.utf8.count ?? 0) &+ (tasks.last?.title.utf8.count ?? 0)
    }
    @inline(never) static func workload(readsPerColumn: Int, _ query: (TaskKanbanColumn) -> [ReminderTask]) {
        for column in TaskKanbanColumn.allCases {
            for _ in 0..<readsPerColumn { consume(query(column)) }
        }
    }
    static func measure(repeats: Int, _ operation: () -> Void) -> [Double] {
        (0..<repeats).map { _ in
            let start = DispatchTime.now().uptimeNanoseconds
            operation()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
    }
    static func report(_ label: String, _ values: [Double], count: Int, selected: Int, reads: Int) {
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        let average = values.reduce(0, +) / Double(values.count)
        print("\(label),\(count),\(selected),\(reads * 3),\(values.count),\(String(format: "%.6f", median)),\(String(format: "%.6f", average)),\(String(format: "%.6f", sorted.last!))")
    }
    static func run(count: Int, repeats: Int) async {
        let fixture = Fixture(count: count)
        let suiteName = "HeyNotch.syntheticPerformance." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("list-0", forKey: "tasks.selectedList")
        defaults.set(Array(fixture.doing), forKey: TaskBoardStore.doingPreferenceKey)
        let repository = SyntheticRepository(fixture.tasks)
        let store = TaskBoardStore(repository: repository, defaults: defaults)
        await store.refresh()
        precondition(store.errorMessage == nil)
        let prototype = ProjectionPrototype(tasks: fixture.tasks, doing: fixture.doing, listID: "list-0")
        for column in TaskKanbanColumn.allCases {
            // Complete value equality checks IDs, order and all reminder fields.
            precondition(store.tasks(in: column) == prototype.tasks(in: column), "Projection behavior changed")
        }
        let selected = fixture.tasks.filter { $0.listID == "list-0" }.count
        for reads in [1, 5] {
            // Warm Foundation/calendar caches equally, outside reported measurements.
            workload(readsPerColumn: reads, store.tasks(in:))
            workload(readsPerColumn: reads, prototype.tasks(in:))
            var baseline: [Double] = [], productionCold: [Double] = [], cold: [Double] = [], warm: [Double] = []
            for iteration in 0..<repeats {
                // Alternate baseline/prototype order to reduce thermal/order bias.
                func baselineSample() {
                    baseline += measure(repeats: 1) { workload(readsPerColumn: reads, store.tasks(in:)) }
                    // Invalidate through the real selected-list interface, outside timing.
                    // Reading the missing list replaces the cached projection. Switching
                    // back leaves the first measured lookup to rebuild the active list.
                    store.selectedListID = "synthetic-missing-list"
                    precondition(store.visibleTasks.isEmpty)
                    store.selectedListID = "list-0"
                    productionCold += measure(repeats: 1) { workload(readsPerColumn: reads, store.tasks(in:)) }
                }
                func prototypeSample() {
                    prototype.invalidate()
                    cold += measure(repeats: 1) { workload(readsPerColumn: reads, prototype.tasks(in:)) }
                    warm += measure(repeats: 1) { workload(readsPerColumn: reads, prototype.tasks(in:)) }
                }
                if iteration.isMultiple(of: 2) { baselineSample(); prototypeSample() }
                else { prototypeSample(); baselineSample() }
            }
            report("production", baseline, count: count, selected: selected, reads: reads)
            report("production-cold", productionCold, count: count, selected: selected, reads: reads)
            report("prototype-cold", cold, count: count, selected: selected, reads: reads)
            report("prototype-warm", warm, count: count, selected: selected, reads: reads)
        }
    }
}

@main
private struct Benchmark {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        let smoke = args.contains("--smoke")
        let sizes = smoke ? [100] : [100, 1_000, 5_000]
        let repeats = smoke ? 1 : 5
        print("# Synthetic task-store queries only; not UI frame timing or real reminders.")
        print("# OS=\(ProcessInfo.processInfo.operatingSystemVersionString); CPUs=\(ProcessInfo.processInfo.activeProcessorCount); calendar=\(Calendar.current.identifier); locale=\(Locale.current.identifier); zone=\(TimeZone.current.identifier)")
        print("# Actual TaskBoardStore is compiled unmodified; prototype is local to this harness.")
        print("# production is warm; production-cold forces a list-key change before timing the first active-list lookup. Refresh is outside both timings.")
        print("# Queries=3: one read per lane. Queries=15: four body reads plus one height read per lane; modeled source workload, not measured SwiftUI evaluations.")
        print("variant,total_reminders,selected_reminders,queries_per_sample,samples,median_ms,mean_ms,max_ms")
        for count in sizes { await Harness.run(count: count, repeats: repeats) }
        print("# checksum=\(Harness.checksum); full reminder-value equality passed for every size/column")
    }
}
