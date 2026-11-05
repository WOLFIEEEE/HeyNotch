import EventKit
import SwiftUI

struct TaskSettingsView: View {
    @ObservedObject private var tasks = TaskController.shared
    @AppStorage("tasks.notifyAtDue") private var notify = true
    var body: some View {
        Form {
            Section("Apple Reminders") {
                Text("Tasks are saved in Apple Reminders and can be edited there. HeyNotch includes undated tasks and observes changes from other apps.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Allow Reminders access") { Task { await tasks.connectReminders() } }
                    Button("Refresh lists") { Task { await tasks.refresh() } }
                }
                Picker("Save tasks to", selection: $tasks.selectedListID) {
                    Text("Choose a list").tag("")
                    ForEach(tasks.lists.filter(\.writable)) { Text("\($0.title) · \($0.account)").tag($0.id) }
                    if !tasks.selectedListID.isEmpty && tasks.selectedList == nil { Text("Saved list unavailable").tag(tasks.selectedListID) }
                }
                if let list = tasks.selectedList {
                    Text(list.isLocal ? "This list is stored on this Mac. Choose an iCloud list to use iCloud sync." : "Account: \(list.account). Sync is managed by Reminders. For iCloud, use the same Apple Account and enable Reminders on your other devices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Create a HeyNotch list in the default account") { Task { await tasks.createList() } }
                Text("If a HeyNotch list already exists in that account, it will be reused.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Dates and notifications") {
                Toggle("Notify at the due time for new timed tasks", isOn: $notify)
                Text("Date-only tasks stay date-only and do not get a time or alarm. Timed reminders use a Reminders alarm when enabled. Allow Reminders notifications in System Settings to receive them.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Ambiguous times and recurring requests require review. AI assistance is optional in Processing settings and always creates a suggestion to review.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Open Tasks") { tasks.showWindow() }
                Text(tasks.status).font(.callout)
                if let error = tasks.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }.formStyle(.grouped).navigationTitle("Tasks")
            .task { if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { await tasks.refresh() } }
    }
}

struct TasksNotchView: View {
    @ObservedObject private var tasks = TaskController.shared
    @ObservedObject private var voice = VoiceCoordinator.shared
    private var voiceTaskRecording: Bool { voice.phase == .recording && voice.mode == .task }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Tasks").font(.system(size: 17, weight: .semibold))
                if let list = tasks.selectedList {
                    Menu {
                        Picker("Reminders list", selection: $tasks.selectedListID) {
                            ForEach(tasks.lists.filter(\.writable)) { item in
                                Text("\(item.title) · \(item.account)").tag(item.id)
                            }
                        }
                    } label: {
                        Text(list.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 210, alignment: .leading)
                    .accessibilityLabel("Reminders list: \(list.title)")
                    .help("Choose the Reminders list shown on this board")
                }
                Spacer(minLength: 8)
                if tasks.loading { ProgressView().controlSize(.mini).accessibilityLabel("Refreshing tasks") }
                Button { tasks.newTask() } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.bordered).controlSize(.small).tint(.white.opacity(0.15))
                    .accessibilityLabel("Add task").help("Add a task")
                Button { voice.toggle(.task) } label: {
                    Image(systemName: voiceTaskRecording ? "stop.circle.fill" : "mic")
                        .foregroundStyle(voiceTaskRecording ? Color.red : Color.white.opacity(0.75))
                        .frame(width: 25, height: 25).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(voice.phase.isBusy && !voiceTaskRecording)
                .accessibilityLabel(voiceTaskRecording ? "Finish voice task" : "Add a voice task")
                .help(voiceTaskRecording ? "Finish voice task" : "Add a voice task")
                Button { tasks.showWindow() } label: {
                    Image(systemName: "arrow.up.right.square").frame(width: 25, height: 25).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.75))
                .accessibilityLabel("Open Tasks window").help("Open Tasks window")
            }
            if tasks.selectedList == nil {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.split.3x1").font(.system(size: 28, weight: .light)).foregroundStyle(.white.opacity(0.45))
                    Text("Your tasks, in the notch").font(.headline)
                    Text("Choose a Reminders list to organize tasks here.")
                        .font(.callout).foregroundStyle(.white.opacity(0.6))
                    Button("Set up Reminders…") { tasks.showWindow() }.controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TaskKanbanBoard(controller: tasks)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = tasks.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                    .accessibilityLabel("Task error: \(error)")
            }
            HStack(spacing: 8) {
                Text("Doing stays on this Mac. Done syncs with Reminders.")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 4)
                if tasks.lastSavedID != nil {
                    Button("Undo task") { Task { await tasks.undoLastSave() } }
                        .buttonStyle(.plain).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7)).disabled(tasks.saving)
                        .accessibilityLabel("Undo last task created")
                        .help("Remove the last task created in HeyNotch")
                }
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white).environment(\.colorScheme, .dark)
        .task { if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { await tasks.refresh() } }
    }
}

struct TaskWorkspaceView: View {
    @ObservedObject var controller: TaskController
    @State private var showCompleted = false
    @State private var deleting: ReminderTask?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("List", selection: $controller.selectedListID) {
                    Text("Choose a list").tag("")
                    ForEach(controller.lists.filter(\.writable)) { Text("\($0.title) · \($0.account)").tag($0.id) }
                }
                Button { controller.newTask() } label: { Label("Add", systemImage: "plus") }
                Button { VoiceCoordinator.shared.toggle(.task) } label: { Image(systemName: "mic") }.accessibilityLabel("Add a voice task")
                Button { Task { await controller.refresh() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh tasks")
            }.padding()
            if controller.lists.isEmpty {
                ContentUnavailableView {
                    Label("Your tasks, in Reminders", systemImage: "checklist")
                } description: {
                    Text("Allow Reminders access, then choose a list. You can add a task with or without a due date.")
                } actions: {
                    Button("Connect Reminders") { Task { await controller.connectReminders() } }
                }
            } else {
                List {
                    ForEach(TaskSection.allCases.filter { showCompleted || $0 != .completed }) { section in
                        let items = controller.visibleTasks.filter { TaskSection.section(for: $0, now: Date(), calendar: .current) == section }
                        if !items.isEmpty {
                            Section(section.rawValue) {
                                ForEach(items) { item in
                                    HStack(alignment: .top) {
                                        Button { Task { await controller.setCompleted(item, !item.completed) } } label: {
                                            Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                                        }.buttonStyle(.plain).accessibilityLabel("\(item.completed ? "Reopen" : "Complete") \(item.title)")
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.title).strikethrough(item.completed)
                                            if let due = item.due, let date = due.date(in: .current) {
                                                Text(date, format: due.hasTime ? .dateTime.year().month().day().hour().minute() : .dateTime.year().month().day())
                                                    .font(.caption).foregroundStyle(section == .overdue ? .red : .secondary)
                                            }
                                            if item.recurring { Label("Repeats in Reminders", systemImage: "repeat").font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Spacer()
                                        Button("Edit") { controller.edit(item) }.accessibilityLabel("Edit \(item.title)")
                                        Button { deleting = item } label: { Image(systemName: "trash") }
                                            .accessibilityLabel("Delete \(item.title)")
                                    }.buttonStyle(.borderless).accessibilityElement(children: .contain).padding(.vertical, 3)
                                }
                            }
                        }
                    }
                }
                Toggle("Show completed tasks", isOn: $showCompleted).padding(.horizontal).padding(.top, 8)
            }
            VStack(alignment: .leading, spacing: 5) {
                if controller.loading { ProgressView().controlSize(.small) }
                if let error = controller.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                Text(controller.status).foregroundStyle(.secondary)
                if controller.lastSavedID != nil {
                    Button("Undo last task created") { Task { await controller.undoLastSave() } }.disabled(controller.saving)
                }
            }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .confirmationDialog("Delete this reminder?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let item = deleting { Button("Delete \(item.title)", role: .destructive) { Task { await controller.delete(item) }; deleting = nil } }
        }
    }
}

struct TaskDraftView: View {
    @ObservedObject var controller: TaskController
    @ObservedObject private var processing = ProcessingSettingsStore.shared
    private var draft: Binding<TaskDraft> { Binding(get: { controller.draft ?? TaskDraft() }, set: { controller.draft = $0 }) }
    private var dueEnabled: Binding<Bool> {
        Binding(get: { draft.wrappedValue.due != nil }, set: { enabled in
            draft.wrappedValue.due = enabled ? .from(Date(), hasTime: false, calendar: .current) : nil
        })
    }
    private var hasTime: Binding<Bool> {
        Binding(get: { draft.wrappedValue.due?.hasTime ?? false }, set: { enabled in
            let date = draft.wrappedValue.due?.date(in: .current) ?? Date()
            draft.wrappedValue.due = .from(date, hasTime: enabled, calendar: .current)
        })
    }
    private var date: Binding<Date> {
        Binding(get: { draft.wrappedValue.due?.date(in: .current) ?? Date() }, set: { date in
            draft.wrappedValue.due = .from(date, hasTime: hasTime.wrappedValue, calendar: .current)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.wrappedValue.reminderID == nil ? "New task" : "Edit task").font(.title2.bold()).padding()
            Form {
                TextField("Title", text: draft.title, axis: .vertical).lineLimit(1...4)
                Picker("List", selection: draft.listID) {
                    Text("Choose a list").tag("")
                    ForEach(controller.lists.filter(\.writable)) { Text("\($0.title) · \($0.account)").tag($0.id) }
                }
                Toggle("Due date", isOn: dueEnabled)
                if dueEnabled.wrappedValue {
                    DatePicker("Date", selection: date, displayedComponents: .date)
                    Toggle("Include a time", isOn: hasTime)
                    if hasTime.wrappedValue { DatePicker("Time", selection: date, displayedComponents: .hourAndMinute) }
                    Text(hasTime.wrappedValue ? "Time zone: \(TimeZone.current.identifier)" : "Date only · no time will be added.").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Notification", selection: draft.alarm) {
                    Text(TaskAlarmChoice.off.rawValue).tag(TaskAlarmChoice.off)
                    Text(TaskAlarmChoice.atDue.rawValue).tag(TaskAlarmChoice.atDue)
                    if draft.wrappedValue.reminderID != nil { Text(TaskAlarmChoice.keep.rawValue).tag(TaskAlarmChoice.keep) }
                }
                if draft.wrappedValue.alarm == .atDue && !hasTime.wrappedValue { Text("Add a time to receive an at-due-time notification.").font(.caption).foregroundStyle(.secondary) }
                TextField("Notes", text: draft.notes, axis: .vertical).lineLimit(2...5)
                if !draft.wrappedValue.sourceText.isEmpty {
                    DisclosureGroup("Original words") { Text(draft.wrappedValue.sourceText).textSelection(.enabled) }
                }
                if !draft.wrappedValue.reviewReasons.isEmpty {
                    Section("Review needed") {
                        ForEach(draft.wrappedValue.reviewReasons, id: \.self) { Text($0).font(.callout) }
                        Toggle("I’ve reviewed the title and date", isOn: draft.reviewAcknowledged)
                    }
                }
                if !draft.wrappedValue.permitsCloudAssistance {
                    Text("Meeting passages are not sent to an AI provider. Edit the title and choose any due date yourself. Saving uses your selected Reminders list.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if processing.preferences.enabled && processing.preferences.taskAssistance {
                    if controller.assisting {
                        HStack { ProgressView().controlSize(.small); Button("Cancel suggestion") { controller.cancelAssistance() } }
                    } else { Button("Suggest with selected AI model") { controller.assistDraft() } }
                    Text("Sends the task text to your selected provider and uses API credits. The suggestion still needs your review.").font(.caption).foregroundStyle(.secondary)
                }
                if let error = controller.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }.formStyle(.grouped).disabled(controller.saving)
            HStack {
                Button("Cancel") { controller.cancelDraft() }
                    .keyboardShortcut(.cancelAction).disabled(controller.saving)
                Spacer()
                if controller.saving { ProgressView().controlSize(.small) }
                Button("Save task") {
                    Task { await controller.saveDraft(); if controller.draft == nil { controller.closeDraft() } }
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.wrappedValue.canSave || draft.wrappedValue.listID.isEmpty || controller.saving || controller.assisting)
            }.padding()
        }.frame(width: 540, height: 620).interactiveDismissDisabled(controller.saving)
    }
}
