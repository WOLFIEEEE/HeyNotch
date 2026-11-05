import SwiftUI

struct MeetingHistorySettingsSection: View {
    @ObservedObject private var history = MeetingHistoryStore.shared
    @State private var confirmClear = false
    var body: some View {
        Section("Transcript library") {
            Toggle("Keep meeting transcripts on this Mac", isOn: Binding(get: { history.enabled }, set: { MeetingCoordinator.shared.setHistoryEnabled($0) }))
            Text("Off by default. When enabled, transcript text is saved as it arrives and kept for 30 days, up to 50 sessions. No audio recordings or API keys are saved in the library.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Turning this off stops new saves. Existing transcripts remain until they expire or you delete them. Files you export separately are yours to manage.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Open Meeting Library…") { MeetingHistoryController.shared.showWindow() }
                Button("Clear history…", role: .destructive) { confirmClear = true }
                    .disabled(history.entries.isEmpty && history.errorMessage == nil)
            }
            if let error = history.errorMessage { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
        }
        .alert("Delete all saved meeting transcripts?", isPresented: $confirmClear) {
            Button("Delete history", role: .destructive) { MeetingHistoryController.shared.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. The current transcript stays in the transcription window, but will not be saved to history again. New sessions follow your history setting. Exported files are unaffected.")
        }
    }
}

struct MeetingLibraryView: View {
    @ObservedObject private var history = MeetingHistoryStore.shared
    @ObservedObject private var controller = MeetingHistoryController.shared
    @ObservedObject private var meeting = MeetingCoordinator.shared
    @State private var selected: UUID?
    @State private var query = ""
    @State private var renameID: UUID?
    @State private var renameTitle = ""
    @State private var showRename = false
    @State private var deleteID: UUID?
    @State private var showDelete = false
    @State private var showClear = false
    private var matching: [MeetingHistoryEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return history.entries }
        return history.entries.filter { entry in
            ([entry.title, entry.callSource] + entry.segments.map(\.text)).contains {
                MeetingTranscriptTools.matches($0, query: term)
            }
        }
    }
    private var selection: MeetingHistoryEntry? { matching.first { $0.id == selected } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Meeting Library").font(.title2.weight(.semibold))
                Spacer()
                Button("Current transcript") { meeting.showWindow() }
                Button("Clear history…", role: .destructive) { showClear = true }
                    .disabled(history.entries.isEmpty && history.errorMessage == nil)
            }.padding(16)
            HStack {
                Image(systemName: history.enabled ? "internaldrive" : "pause.circle")
                Text(history.enabled ? "Saving locally · 30 days · up to 50 sessions" : "History is off. Existing transcripts stay until they expire or you delete them.")
                Spacer()
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 12)
            if let error = history.errorMessage {
                HStack {
                    Text(error).textSelection(.enabled)
                    Spacer(); Button("Retry") { history.reload() }
                }.font(.callout).foregroundStyle(.red).padding(.horizontal, 16).padding(.bottom, 10)
            }
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    TextField("Search saved meetings", text: $query)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Search saved meetings").padding(12)
                    if matching.isEmpty {
                        ContentUnavailableView(query.isEmpty ? "No saved meetings" : "No matching meetings", systemImage: "text.magnifyingglass",
                            description: Text(query.isEmpty ? "Enable transcript history in Settings → Meetings to keep future sessions here." : "Try another word or clear the search."))
                    } else {
                        List(matching, selection: $selected) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.title).font(.headline).lineLimit(2)
                                Text(entry.startedAt, style: .date).font(.caption)
                                Text(entry.completed ? entry.callSource : "Partial transcript · \(entry.callSource)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.padding(.vertical, 4).tag(entry.id)
                        }
                    }
                    Text("\(matching.count) of \(history.entries.count) saved meetings")
                        .font(.caption).foregroundStyle(.secondary).padding(10)
                }.frame(minWidth: 230, idealWidth: 260, maxWidth: 330)
                if let entry = selection {
                    detail(entry).frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Select a meeting", systemImage: "text.bubble", description: Text("Read, search, export, or create a reviewed task from a saved passage."))
                        .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { if selected == nil { selected = matching.first?.id } }
        .alert("Rename meeting", isPresented: $showRename) {
            TextField("Meeting title", text: $renameTitle)
            Button("Rename") {
                if let renameID { _ = history.rename(id: renameID, title: renameTitle) }
            }.disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { Text("The transcript text and original meeting date stay unchanged.") }
        .alert("Delete this saved transcript?", isPresented: $showDelete) {
            Button("Delete transcript", role: .destructive) {
                if let deleteID { controller.delete(deleteID); if selected == deleteID { selected = nil } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This cannot be undone. Exported files and tasks are unaffected. If this is the current session, it stays in memory and will not be saved to history again.") }
        .alert("Delete all saved meeting transcripts?", isPresented: $showClear) {
            Button("Delete history", role: .destructive) { controller.clear(); selected = nil }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This cannot be undone. The current transcript stays in memory but will not be saved to history again. New sessions follow your history setting. Exported files are unaffected.") }
        .alert("Could not export transcript", isPresented: Binding(get: { controller.exportError != nil }, set: { if !$0 { controller.exportError = nil } })) {
            Button("OK") { controller.exportError = nil }
        } message: { Text(controller.exportError ?? "") }
    }

    private func detail(_ entry: MeetingHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(entry.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                Text("\(entry.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(MeetingTranscriptSegment.timestamp(entry.elapsed)) · \(entry.callSource)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !entry.completed {
                    Text(meeting.historySessionID == entry.id && meeting.phase.isBusy
                         ? "This session is still in progress. Saved sections appear here as they finish."
                         : "Recovered partial transcript. The session did not finish saving; some speech may be missing. Recording has not resumed.")
                        .font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    Button("Copy all") { controller.copy(entry) }
                    Menu("Save all…") {
                        Button("Plain text…") { controller.save(entry, format: .plainText) }
                        Button("Markdown…") { controller.save(entry, format: .markdown) }
                    }
                    Spacer()
                    Button("Rename…") { renameID = entry.id; renameTitle = entry.title; showRename = true }
                    Button("Delete…", role: .destructive) { deleteID = entry.id; showDelete = true }
                }
            }.padding(16)
            Divider()
            MeetingTranscriptBrowser(segments: entry.segments, onCreateTask: { controller.createTask($0, entry: entry) })
                .id(entry.id)
        }
    }
}
