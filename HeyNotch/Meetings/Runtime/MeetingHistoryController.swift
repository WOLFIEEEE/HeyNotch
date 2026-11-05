import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Browsing saved text never resumes capture or replaces the live transcript.
@MainActor
final class MeetingHistoryController: ObservableObject {
    static let shared = MeetingHistoryController()
    @Published var exportError: String?
    private var window: NSWindowController?

    func showWindow() {
        MeetingHistoryStore.shared.reload()
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            panel.title = "Meeting Library"; panel.minSize = NSSize(width: 800, height: 520)
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: MeetingLibraryView())
            panel.center(); window = NSWindowController(window: panel)
        }
        window?.showWindow(nil); window?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func delete(_ id: UUID) {
        if id == MeetingCoordinator.shared.historySessionID { MeetingCoordinator.shared.suppressHistoryForCurrentSession() }
        _ = MeetingHistoryStore.shared.delete(id: id)
    }

    func clear() {
        // Also suppress a live session that has not produced its first section yet.
        MeetingCoordinator.shared.suppressHistoryForCurrentSession()
        _ = MeetingHistoryStore.shared.clear()
    }

    func copy(_ entry: MeetingHistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(export(entry, format: .plainText), forType: .string)
    }

    func save(_ entry: MeetingHistoryEntry, format: MeetingTranscriptExportFormat) {
        guard let parent = window?.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .plainText]
        panel.nameFieldStringValue = "Meeting transcript.\(format.fileExtension)"
        let text = export(entry, format: format)
        panel.beginSheetModal(for: parent) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { self?.exportError = "The transcript could not be saved. Choose another location or copy the text." }
        }
    }

    func createTask(_ segment: MeetingTranscriptSegment, entry: MeetingHistoryEntry) {
        guard !segment.isGap else { return }
        let provenance = entry.title + " · " + DateFormatter.localizedString(from: entry.startedAt, dateStyle: .medium, timeStyle: .short)
        TaskController.shared.proposeMeetingPassage(text: segment.text, timestamp: segment.timestamp,
                                                  source: segment.source.rawValue, sessionTitle: provenance)
    }

    private func export(_ entry: MeetingHistoryEntry, format: MeetingTranscriptExportFormat) -> String {
        let text = MeetingTranscriptTools.export(entry.segments, format: format, started: entry.startedAt,
                                                callSource: entry.callSource, title: entry.title)
        return entry.completed ? text : text + "\n\nPartial transcript: this snapshot was saved before the session finished. Some speech may be missing.\n"
    }
}
