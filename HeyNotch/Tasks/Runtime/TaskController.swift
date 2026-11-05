import AppKit
import EventKit
import SwiftUI

@MainActor
final class TaskController: TaskBoardStore {
    static let shared = TaskController()
    private let reminders: ReminderTaskService
    private var changed: Any?
    private var foreground: Any?
    private var refreshTask: Task<Void, Never>?
    private var assistance: Task<Void, Never>?
    private var window: NSWindowController?
    private var editor: NSPanel?
    // Keep the inherited store's publisher: a second @Published property on this
    // subclass can split SwiftUI observation from the base store's draft updates.
    private(set) var assisting = false { willSet { objectWillChange.send() } }

    private init() {
        let service = ReminderTaskService(); reminders = service
        super.init(repository: service)
        changed = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: EventStoreProvider.shared, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        foreground = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.reminders.authorized == true { self?.scheduleRefresh() } }
        }
    }
    func connectReminders() async {
        await connect()
        if selectedListID.isEmpty, let id = reminders.defaultListID(), lists.contains(where: { $0.id == id && $0.writable }) { selectedListID = id }
    }
    func createList() async {
        do { selectedListID = try reminders.createHeyNotchList(); await refresh() }
        catch { report(error) }
    }
    func newTask() { makeDraft(); presentDraft() }
    func propose(_ text: String) { makeDraft(text); presentDraft() }
    func proposeMeetingPassage(text: String, timestamp: String, source: String, sessionTitle: String) {
        guard let proposal = MeetingTaskDraft.make(text: text, timestamp: timestamp, source: source,
                                                   sessionTitle: sessionTitle, listID: selectedListID) else { return }
        showWindow()
        guard !saving else {
            let alert = NSAlert()
            alert.messageText = "A task is still being saved"
            alert.informativeText = "Wait for the current save to finish, then choose this meeting passage again."
            alert.addButton(withTitle: "Keep current")
            alert.runModal()
            return
        }
        let previous = draft
        if previous != nil || editor != nil {
            let alert = NSAlert()
            alert.messageText = "Keep the current task draft?"
            alert.informativeText = "A task editor is already open. Replacing it discards that unsaved draft. Nothing is saved to Reminders until you review the meeting task and choose Save task."
            alert.addButton(withTitle: "Keep current")
            alert.addButton(withTitle: "Replace draft")
            alert.buttons[0].keyEquivalent = "\r"
            alert.buttons[1].keyEquivalent = ""
            guard alert.runModal() == .alertSecondButtonReturn else {
                if draft != nil { presentDraft() }
                return
            }
        }
        // A pending save or AI suggestion may finish while the alert is open.
        guard stageMeetingDraft(proposal, replacing: previous) else {
            let alert = NSAlert()
            alert.messageText = "The current task changed"
            alert.informativeText = "Your current draft was kept. Choose the meeting passage again when you are ready to replace it."
            alert.addButton(withTitle: "Keep current")
            alert.runModal()
            if draft != nil { presentDraft() }
            return
        }
        cancelAssistance()
        presentDraft()
    }
    override func edit(_ task: ReminderTask) { super.edit(task); presentDraft() }
    func editInWindow(_ task: ReminderTask) { edit(task) }
    func openTaskLink(_ operation: UUID) async {
        showWindow()
        do {
            guard let id = try await reminders.identifierForOperation(operation) else { throw TaskServiceError.missing }
            await refresh()
            guard let task = tasks.first(where: { $0.id == id }) else { throw TaskServiceError.missing }
            selectedListID = task.listID
            // Opening a reminder link navigates to its list without overwriting an unsaved draft.
        } catch { report(error) }
    }
    private func presentDraft() {
        showWindow()
        guard let parent = window?.window else { return }
        if editor == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
                                styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: TaskDraftView(controller: self))
            editor = panel
        }
        guard let editor, editor.sheetParent == nil else { return }
        parent.beginSheet(editor) { [weak self, weak editor] _ in
            editor?.close()
            if self?.editor === editor { self?.editor = nil }
        }
    }
    func closeDraft() {
        cancelAssistance()
        if let editor, let parent = editor.sheetParent { parent.endSheet(editor) }
    }
    func showWindow() {
        if window == nil {
            let view = TaskWorkspaceView(controller: self)
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            panel.title = "HeyNotch Tasks"; panel.minSize = NSSize(width: 500, height: 450)
            panel.contentView = NSHostingView(rootView: view); panel.center(); panel.isReleasedWhenClosed = false
            window = NSWindowController(window: panel)
        }
        window?.showWindow(nil); window?.window?.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
        Task { if reminders.authorized { await refresh() } }
    }
    func assistDraft() {
        let preferences = ProcessingSettingsStore.shared.preferences
        guard preferences.enabled, preferences.taskAssistance, let original = draft,
              original.permitsCloudAssistance, !assisting else { return }
        assisting = true
        assistance = Task {
            defer { assisting = false; assistance = nil }
            do {
                let snapshot = try await ProcessingController.shared.snapshot()
                let proposed = try await TaskAssistance(api: ProcessingController.shared.api)
                    .propose(original.sourceText.isEmpty ? original.title : original.sourceText, snapshot: snapshot, now: Date(), timeZone: .current)
                try Task.checkCancellation()
                guard preferences.revision == ProcessingSettingsStore.shared.preferences.revision else { throw ProcessingError.configurationChanged }
                guard draft == original else { return }
                var value = MeetingTaskDraft.preservingContext(in: proposed, from: original)
                value.id = original.id; value.listID = original.listID; value.alarm = original.alarm; value.reminderID = original.reminderID
                draft = value
            } catch { if !(error is CancellationError) { report(error) } }
        }
    }
    func cancelAssistance() { assistance?.cancel() }
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await refresh()
        }
    }
}
