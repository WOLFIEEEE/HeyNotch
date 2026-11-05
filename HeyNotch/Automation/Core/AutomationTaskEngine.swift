import Foundation

@MainActor
final class AutomationTaskEngine {
    private let board: TaskBoardStore
    private let journal: AutomationJournal
    private var running = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private static let writeTools: Set<String> = ["create_task", "update_task", "move_task", "set_task_completed"]

    init(board: TaskBoardStore, journalURL: URL) {
        self.board = board; journal = AutomationJournal(url: journalURL)
    }

    func execute(_ data: Data, context: AutomationContext) async -> Data {
        await acquire()
        defer { release() }
        do {
            try authorize(context)
            try Task.checkCancellation()
            guard data.count <= AutomationJSON.maximumRequestBytes else {
                throw AutomationFailure(code: "request_too_large", message: "The command is larger than 64 KiB.")
            }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  Set(object.keys) == ["tool", "arguments"], let tool = object["tool"] as? String,
                  let arguments = object["arguments"] as? [String: Any] else { throw AutomationFailure.invalid }
            let fields = AutomationArguments(values: arguments)
            let result: Data
            if Self.writeTools.contains(tool) {
                guard context.canWrite else { throw AutomationFailure.denied }
                let operationID = try fields.uuid("operationID")
                var normalized = arguments; normalized["operationID"] = operationID.uuidString
                let fingerprint = AutomationJSON.hash(try AutomationJSON.encode(["tool": tool, "arguments": normalized]))
                if let previous = try await journal.entry(clientID: context.clientID, operationID: operationID) {
                    try authorize(context)
                    guard previous.listIDs.isSubset(of: context.allowedListIDs) else { throw AutomationFailure.denied }
                    guard previous.fingerprint == fingerprint else {
                        throw AutomationFailure(code: "operation_conflict", message: "This operation ID was already used with different arguments. Its original operation was not changed.")
                    }
                    result = replay(previous)
                } else {
                    try authorize(context)
                    let internalID = UUID()
                    let lockID = tool == "create_task" ? "automation-create-" + internalID.uuidString : try fields.string("taskID")!
                    result = try await board.withTaskOperation(id: lockID) {
                        try self.authorize(context)
                        return try await self.write(tool: tool, fields: fields, operationID: operationID,
                                                    internalID: internalID, fingerprint: fingerprint, context: context)
                    }
                }
            } else { result = try await read(tool: tool, fields: fields, context: context) }
            // A client revoked during a fetch/write receives no task details. A
            // completed write still retains its real outcome in the journal.
            try authorize(context)
            return result
        } catch { return AutomationJSON.failure(error) }
    }

    /// The caller revokes the immutable grant first; a new connection gets a new
    /// client ID. Retirement frees capacity without enabling old-client retries.
    @discardableResult
    func retireClient(_ id: String) async -> Bool {
        await acquire()
        defer { release() }
        do { try await journal.retireClient(id); return true }
        catch { return false }
    }

    private func read(tool: String, fields: AutomationArguments, context: AutomationContext) async throws -> Data {
        switch tool {
        case "get_context":
            try fields.only([])
            return try AutomationJSON.success(["clientID": context.clientID,
                                               "allowedListIDs": context.allowedListIDs.sorted(), "canWrite": context.canWrite,
                                               "currentTime": AutomationJSON.date(Date()), "timeZoneIdentifier": TimeZone.current.identifier])
        case "get_operation":
            try fields.only(["operationID"])
            let id = try fields.uuid("operationID")
            guard let entry = try await journal.entry(clientID: context.clientID, operationID: id) else { throw notFound() }
            try authorize(context)
            guard entry.listIDs.isSubset(of: context.allowedListIDs) else { throw AutomationFailure.denied }
            var result: [String: Any] = ["operationID": id.uuidString,
                                         "status": entry.state == .pending ? "uncertain" : entry.state.rawValue]
            if let response = entry.response, response.count <= AutomationJSON.maximumResponseBytes - 1_024 {
                result["response"] = try JSONSerialization.jsonObject(with: response)
            }
            return try AutomationJSON.success(result)
        case "list_task_lists":
            try fields.only([])
            let lists = try board.repository.lists()
            return try AutomationJSON.success(["lists": lists.filter { context.allowedListIDs.contains($0.id) }.map {
                ["id": $0.id, "title": $0.title, "account": $0.account, "isLocal": $0.isLocal, "writable": $0.writable] as [String: Any]
            }])
        case "get_task":
            try fields.only(["taskID"])
            let id = try fields.string("taskID")!
            let snapshot = try await board.snapshotForAutomation()
            try authorize(context)
            let task = try scopedTask(id, in: snapshot.tasks, context: context)
            return try AutomationJSON.success(["task": taskObject(task)])
        case "find_tasks":
            try fields.only(["listID", "query", "completed", "limit", "offset"])
            let listID = try fields.string("listID", required: false)
            if let listID, !context.allowedListIDs.contains(listID) { throw AutomationFailure.denied }
            let query = try fields.string("query", required: false, maximum: 4_096, allowEmpty: true) ?? ""
            let completed = try fields.bool("completed")
            let limit = try fields.integer("limit", required: false, range: 1...100) ?? 50
            let offset = try fields.integer("offset", required: false, range: 0...100_000) ?? 0
            let snapshot = try await board.snapshotForAutomation()
            try authorize(context)
            let matching = snapshot.tasks.filter {
                context.allowedListIDs.contains($0.listID) && (listID == nil || $0.listID == listID)
                    && (completed == nil || $0.completed == completed)
                    && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.notes.localizedCaseInsensitiveContains(query))
            }.sorted { $0.id < $1.id }
            let page = Array(matching.dropFirst(offset).prefix(limit))
            let next: Any = offset + page.count < matching.count ? offset + page.count : NSNull()
            return try AutomationJSON.success(["tasks": try page.map { try taskObject($0) }, "total": matching.count,
                                               "limit": limit, "offset": offset, "nextOffset": next])
        default: throw AutomationFailure(code: "unknown_tool", message: "This task tool is not supported.")
        }
    }

    private func write(tool: String, fields: AutomationArguments, operationID: UUID, internalID: UUID,
                       fingerprint: String, context: AutomationContext) async throws -> Data {
        try validateFields(tool: tool, fields: fields)
        let snapshot = try await board.snapshotForAutomation()
        try authorize(context)
        try Task.checkCancellation()
        let current: ReminderTask?
        let listID: String
        if tool == "create_task" {
            current = nil; listID = try fields.string("listID")!
        } else {
            current = try scopedTask(try fields.string("taskID")!, in: snapshot.tasks, context: context)
            listID = current!.listID
            guard try fields.revision() == revision(current!) else {
                throw AutomationFailure(code: "revision_conflict", message: "The task changed. Read it again before deciding which update to make.")
            }
        }
        guard context.allowedListIDs.contains(listID) else { throw AutomationFailure.denied }
        guard let list = snapshot.lists.first(where: { $0.id == listID }) else { throw TaskServiceError.noList }
        guard list.writable else { throw TaskServiceError.readOnly }

        var expected: ReminderTask
        var expectedColumn: TaskKanbanColumn
        var draft: TaskDraft?
        var completion: Bool?
        if tool == "create_task" || tool == "update_task" {
            let title = try fields.title(required: current == nil) ?? current!.title
            let notes = try fields.string("notes", required: false, maximum: 65_536, allowEmpty: true) ?? current?.notes ?? ""
            let due = try fields.due()
            let clearDue = try fields.bool("clearDue") ?? false
            guard !(clearDue && due != nil) else { throw AutomationFailure.invalid }
            let effectiveDue = clearDue ? nil : due ?? current?.due
            let alarm = try fields.alarm(default: current == nil ? .off : .keep)
            let alarms: [TaskAlarm]
            switch alarm {
            case .keep: alarms = current?.alarms ?? []
            case .off: alarms = []
            case .atDue:
                if let effectiveDue, effectiveDue.hasTime, let date = effectiveDue.date(in: .current) {
                    alarms = [.init(absoluteDate: date, relativeOffset: 0)]
                } else { alarms = [] }
            }
            expected = ReminderTask(id: current?.id ?? internalID.uuidString, title: title, notes: notes, due: effectiveDue,
                                    completed: current?.completed ?? false, listID: listID, alarms: alarms,
                                    recurring: current?.recurring ?? false)
            expectedColumn = current.map { board.columnForCanonicalTask($0) } ?? .todo
            draft = TaskDraft(id: internalID, reminderID: current?.id, title: title, notes: notes,
                              due: effectiveDue, listID: listID, alarm: alarm)
        } else {
            expected = current!
            if tool == "move_task" {
                guard let column = TaskKanbanColumn(rawValue: try fields.string("column", maximum: 10)!) else { throw AutomationFailure.invalid }
                expectedColumn = column
            } else { expectedColumn = try fields.bool("completed", required: true)! ? .done : .todo }
            let shouldComplete = expectedColumn == .done
            if current!.recurring && current!.completed != shouldComplete {
                throw AutomationFailure(code: "unsupported_recurring", message: "Complete or reopen repeating reminders in Apple Reminders so their next occurrence is handled correctly.")
            }
            expected.completed = shouldComplete
            if current!.completed != shouldComplete { completion = shouldComplete }
        }
        // Ensure a verified canonical response will fit before touching Reminders.
        let preflight = try AutomationJSON.success(["operationID": operationID.uuidString,
                                                    "link": TaskLink.url(internalID).absoluteString,
                                                    "task": taskObject(expected, column: expectedColumn)])
        guard preflight.count <= AutomationJSON.maximumResponseBytes - 4_096 else {
            throw AutomationFailure(code: "response_too_large", message: "The task is too large for a verified automation response. Edit it in HeyNotch or Reminders.")
        }
        var entry = AutomationJournal.Entry(clientID: context.clientID, operationID: operationID,
                                             fingerprint: fingerprint, internalID: internalID,
                                             listIDs: [listID], state: .pending, response: nil)
        try await journal.begin(entry)
        var attemptedMutation = false
        do {
            // Disk persistence yields off the UI actor. Revocation/cancellation
            // at that boundary must prevent the subsequent reminder mutation.
            try authorize(context)
            try Task.checkCancellation()
            // The board FIFO excludes our own UI writes, but Apple Reminders
            // can change a task while the journal is being flushed. Revalidate
            // its live list and complete revision after that await so an old
            // draft cannot overwrite the intervening edit or move it back.
            let latest = try await board.snapshotForAutomation()
            try authorize(context)
            try Task.checkCancellation()
            guard let latestList = latest.lists.first(where: { $0.id == listID }) else { throw TaskServiceError.noList }
            guard latestList.writable else { throw TaskServiceError.readOnly }
            if let current {
                let latestTask = try scopedTask(current.id, in: latest.tasks, context: context)
                guard try revision(latestTask) == fields.revision() else {
                    throw AutomationFailure(code: "revision_conflict", message: "The task changed before the operation could be applied. Read it again before making an update.")
                }
            }
            if let draft, current == nil || expected != current {
                attemptedMutation = true
                let savedID = try await board.repository.save(draft)
                if let current, savedID != current.id { throw AutomationFailure.uncertain }
                expected = replacingID(expected, with: savedID)
                try board.recordAutomationChange(expected)
            } else if let completion {
                attemptedMutation = true
                try board.repository.complete(expected.id, completed: completion)
                try board.recordAutomationChange(expected)
            }
            if tool == "move_task" || tool == "set_task_completed" {
                let desiredDoing = expectedColumn == .doing
                if board.columnForCanonicalTask(expected) != expectedColumn || completion != nil {
                    attemptedMutation = true
                    try board.recordAutomationChange(expected, doing: desiredDoing)
                }
            }
            let readback = try await board.snapshotForAutomation()
            guard let actual = readback.tasks.first(where: { $0.id == expected.id }), actual == expected,
                  board.columnForCanonicalTask(actual) == expectedColumn else { throw AutomationFailure.uncertain }
            var output: [String: Any] = ["operationID": operationID.uuidString, "task": try taskObject(actual)]
            if tool == "create_task" { output["link"] = TaskLink.url(internalID).absoluteString }
            let response = try AutomationJSON.success(output)
            entry.state = .succeeded; entry.response = response
            do { try await journal.finish(entry) }
            catch { return AutomationJSON.failure(AutomationFailure.uncertain) }
            return response
        } catch {
            let response = AutomationJSON.failure(attemptedMutation ? AutomationFailure.uncertain : error)
            entry.state = attemptedMutation ? .uncertain : .failed; entry.response = response
            try? await journal.finish(entry)
            return response
        }
    }

    private func validateFields(tool: String, fields: AutomationArguments) throws {
        let common: Set<String> = ["operationID", "taskID", "expectedRevision"]
        switch tool {
        case "create_task":
            try fields.only(["operationID", "listID", "title", "notes", "due", "alarm"])
            _ = try fields.string("listID"); _ = try fields.title(required: true)
        case "update_task":
            try fields.only(common.union(["title", "notes", "due", "clearDue", "alarm"]))
            let clearsDue = try fields.bool("clearDue") == true
            guard !Set(fields.values.keys).intersection(["title", "notes", "due", "alarm"]).isEmpty || clearsDue else { throw AutomationFailure.invalid }
            _ = try fields.revision()
        case "move_task":
            try fields.only(common.union(["column"])); _ = try fields.revision()
            guard let column = try fields.string("column", maximum: 10), TaskKanbanColumn(rawValue: column) != nil else { throw AutomationFailure.invalid }
        case "set_task_completed":
            try fields.only(common.union(["completed"])); _ = try fields.revision(); _ = try fields.bool("completed", required: true)
        default: throw AutomationFailure.invalid
        }
    }
    private func taskObject(_ task: ReminderTask, column: TaskKanbanColumn? = nil) throws -> [String: Any] {
        var object = try canonicalTask(task, column: column)
        object["revision"] = AutomationJSON.hash(try AutomationJSON.encode(object))
        return object
    }
    private func revision(_ task: ReminderTask) throws -> String {
        AutomationJSON.hash(try AutomationJSON.encode(canonicalTask(task)))
    }
    private func canonicalTask(_ task: ReminderTask, column: TaskKanbanColumn? = nil) throws -> [String: Any] {
        let due: Any
        if let value = task.due { due = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        else { due = NSNull() }
        return ["id": task.id, "title": task.title, "notes": task.notes, "listID": task.listID,
                "due": due, "completed": task.completed, "recurring": task.recurring,
                "column": (column ?? board.columnForCanonicalTask(task)).rawValue,
                "alarms": task.alarms.map { ["absoluteDate": $0.absoluteDate.map(AutomationJSON.date) as Any? ?? NSNull(), "relativeOffset": $0.relativeOffset] as [String: Any] }]
    }
    private func replacingID(_ value: ReminderTask, with id: String) -> ReminderTask {
        .init(id: id, title: value.title, notes: value.notes, due: value.due, completed: value.completed,
              listID: value.listID, alarms: value.alarms, recurring: value.recurring)
    }
    private func scopedTask(_ id: String, in tasks: [ReminderTask], context: AutomationContext) throws -> ReminderTask {
        guard let task = tasks.first(where: { $0.id == id }) else { throw notFound() }
        guard context.allowedListIDs.contains(task.listID) else { throw AutomationFailure.denied }
        return task
    }
    private func replay(_ entry: AutomationJournal.Entry) -> Data {
        switch entry.state {
        case .succeeded, .failed: return entry.response ?? AutomationJSON.failure(AutomationFailure.uncertain)
        case .pending, .uncertain: return AutomationJSON.failure(AutomationFailure.uncertain)
        }
    }
    private func authorize(_ context: AutomationContext) throws {
        guard !context.clientID.isEmpty, context.clientID.utf8.count <= 256,
              context.authorizationCheck() else { throw AutomationFailure.denied }
    }
    private func notFound() -> AutomationFailure { .init(code: "not_found", message: "This task or operation was not found.") }
    private func acquire() async {
        if running { await withCheckedContinuation { waiters.append($0) } }
        else { running = true }
    }
    private func release() {
        if waiters.isEmpty { running = false }
        else { waiters.removeFirst().resume() }
    }
}
