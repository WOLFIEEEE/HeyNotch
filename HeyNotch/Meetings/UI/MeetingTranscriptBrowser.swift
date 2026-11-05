import AppKit
import SwiftUI

/// A local transcript reader shared by the current meeting and saved history.
/// Search/source selection deliberately lives here, not in recording or export
/// state. Each caller continues to own the full transcript it saves or copies.
struct MeetingTranscriptBrowser: View {
    let segments: [MeetingTranscriptSegment]
    var onCreateTask: ((MeetingTranscriptSegment) -> Void)? = nil
    @State private var query = ""
    @State private var source: MeetingTranscriptSourceFilter = .all
    @FocusState private var searchFocused: Bool

    private var visible: [MeetingTranscriptSegment] {
        MeetingTranscriptTools.filtered(segments, query: query, source: source)
    }
    private var hasFilters: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || source != .all }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button { searchFocused = true } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).keyboardShortcut("f", modifiers: .command)
                        .accessibilityLabel("Find in transcript").help("Find in transcript (⌘F)")
                    TextField("Search transcript", text: $query)
                        .textFieldStyle(.roundedBorder).focused($searchFocused)
                        .accessibilityLabel("Search transcript")
                    Picker("Source", selection: $source) {
                        ForEach(MeetingTranscriptSourceFilter.allCases) { filter in Text(filter.displayName).tag(filter) }
                    }.labelsHidden().accessibilityLabel("Filter transcript by audio source")
                        .frame(width: 145)
                    if hasFilters {
                        Button("Clear") { query = ""; source = .all }
                            .accessibilityLabel("Clear transcript search and source filter")
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Showing \(visible.count) of \(segments.count) passages")
                        .accessibilityLabel("Showing \(visible.count) of \(segments.count) transcript passages")
                    Spacer(minLength: 12)
                    Text("Filters change the view. Full-transcript exports include every passage.")
                        .multilineTextAlignment(.trailing)
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(14)
            Divider()
            if segments.isEmpty {
                ContentUnavailableView("No transcript yet", systemImage: "text.bubble", description: Text("Recorded speech will appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                ContentUnavailableView {
                    Label("No matching passages", systemImage: "magnifyingglass")
                } description: {
                    Text("Try another search or choose a different audio source.")
                } actions: {
                    Button("Clear filters") { query = ""; source = .all; searchFocused = true }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(visible) { segment in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("\(MeetingTranscriptTools.timestamp(segment.offset)) · \(segment.source.rawValue)\(segment.isGap ? " · transcription gap" : "")")
                                        .font(.caption.weight(.semibold)).foregroundStyle(segment.isGap ? Color.orange : Color.secondary)
                                    Spacer()
                                    Menu { actions(for: segment) } label: { Image(systemName: "ellipsis") }
                                        .menuStyle(.borderlessButton).fixedSize()
                                        .accessibilityLabel("Passage actions at \(MeetingTranscriptTools.timestamp(segment.offset)), \(segment.source.rawValue)")
                                }
                                Text(verbatim: segment.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .accessibilityElement(children: .contain)
                            .contextMenu { actions(for: segment) }
                        }
                    }.padding(20)
                }
            }
        }
    }

    @ViewBuilder private func actions(for segment: MeetingTranscriptSegment) -> some View {
        Button("Copy passage") { copy(segment.text) }
        Button("Copy with timestamp and source") { copy(MeetingTranscriptTools.attributedPassage(segment)) }
        Divider()
        Button("Create task…") { onCreateTask?(segment) }
            .disabled(segment.isGap || onCreateTask == nil)
            .help(segment.isGap ? "Transcription gaps cannot become tasks." : "Open this passage as a task draft for review.")
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
