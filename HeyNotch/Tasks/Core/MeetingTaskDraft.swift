import Foundation

/// Archived passages belong to the original meeting's clock, not today's.
/// Do not infer dates from them through the live-dictation date parser.
enum MeetingTaskDraft {
    static let reviewReasons = [
        "This is a meeting passage. Confirm the intended task and who should do it before saving.",
        "No due date was inferred. Words such as ‘tomorrow’ refer to the meeting, so choose the intended date yourself."
    ]
    static func make(text: String, timestamp: String, source: String, sessionTitle: String, listID: String) -> TaskDraft? {
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        let notes = """
        From HeyNotch meeting
        Session: \(sessionTitle)
        Position: \(timestamp) · \(source)

        Original passage:
        \(text)
        """
        return TaskDraft(title: boundedTitle(normalized), notes: notes, due: nil, listID: listID,
                         alarm: .off, reviewReasons: reviewReasons, sourceText: text, reviewAcknowledged: false, origin: .meeting)
    }
    static func preservingContext(in suggestion: TaskDraft, from original: TaskDraft) -> TaskDraft {
        guard original.origin == .meeting else { return suggestion }
        var value = suggestion
        value.origin = .meeting
        value.sourceText = original.sourceText
        value.notes = original.notes
        if !suggestion.notes.isEmpty && suggestion.notes != original.notes {
            value.notes += "\n\nSuggested notes:\n" + suggestion.notes
        }
        // Retain a date the user explicitly chose, or nil. AI may improve a
        // title on request, but cannot re-anchor archived relative dates.
        value.due = original.due
        value.alarm = original.alarm
        value.reviewReasons = reviewReasons + suggestion.reviewReasons.filter { !reviewReasons.contains($0) }
        value.reviewAcknowledged = false
        return value
    }
    private static func boundedTitle(_ value: String) -> String {
        // Reserve an ellipsis and retain complete grapheme clusters. The byte
        // limit also handles unusually large combining sequences.
        var title = ""
        var bytes = 0
        var characters = 0
        for character in value {
            let next = String(character)
            guard characters < 239, bytes + next.utf8.count <= 997 else {
                return title.isEmpty ? "Review meeting passage" : title + "…"
            }
            title.append(character); bytes += next.utf8.count; characters += 1
        }
        return title
    }
}

extension TaskBoardStore {
    /// Changes only the in-memory editor. Replacement must identify the exact
    /// draft the user approved; a stale confirmation cannot erase later edits.
    @discardableResult
    func stageMeetingDraft(_ proposal: TaskDraft, replacing expected: TaskDraft? = nil) -> Bool {
        guard !saving, draft == expected else { return false }
        clearError()
        draft = proposal
        return true
    }
}
