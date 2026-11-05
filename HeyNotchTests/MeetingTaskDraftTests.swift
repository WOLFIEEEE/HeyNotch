import XCTest

@MainActor
final class MeetingTaskDraftTests: XCTestCase {
    private func proposal(_ text: String) throws -> TaskDraft {
        try XCTUnwrap(MeetingTaskDraft.make(text: text, timestamp: "00:12:35", source: "Call audio",
                                           sessionTitle: "Design review · 1 November", listID: "list"))
    }
    func testMeetingPassageKeepsNegationLiteralTimesAndUnicodeWithoutInferringDates() throws {
        let text = "Do not send the invoice tomorrow at 10:30.\nनमस्ते 👋 — ask José first."
        let draft = try proposal(text)
        XCTAssertEqual(draft.title, "Do not send the invoice tomorrow at 10:30. नमस्ते 👋 — ask José first.")
        XCTAssertEqual(draft.sourceText, text)
        XCTAssertTrue(draft.notes.contains(text))
        XCTAssertNil(draft.due)
        XCTAssertEqual(draft.alarm, .off)
        XCTAssertNil(draft.reminderID)
        XCTAssertEqual(draft.listID, "list")
        XCTAssertFalse(draft.reviewAcknowledged)
        XCTAssertEqual(draft.origin, .meeting)
        XCTAssertFalse(draft.permitsCloudAssistance)
        XCTAssertTrue(draft.needsReview)
        XCTAssertFalse(draft.canSave)
        XCTAssertTrue(draft.reviewReasons.contains { $0.contains("meeting") && $0.contains("date") })
    }
    func testNotesPreserveFullSourceAndReadableMeetingProvenance() throws {
        let text = "  Keep all these words.\n\nDo not remove this line.  "
        let draft = try proposal(text)
        XCTAssertTrue(draft.notes.contains("From HeyNotch meeting"))
        XCTAssertTrue(draft.notes.contains("Session: Design review · 1 November"))
        XCTAssertTrue(draft.notes.contains("Position: 00:12:35 · Call audio"))
        XCTAssertTrue(draft.notes.hasSuffix(text))
        XCTAssertEqual(draft.sourceText, text)
    }
    func testLongTitleIsBoundedWithoutLosingTheOriginalPassage() throws {
        let text = String(repeating: "Do not send José’s 日本語 notes 👨‍👩‍👧‍👦 tomorrow at 10:30. ", count: 100)
        let draft = try proposal(text)
        XCTAssertLessThanOrEqual(draft.title.count, 240)
        XCTAssertLessThanOrEqual(draft.title.utf8.count, 1000)
        XCTAssertTrue(draft.title.hasSuffix("…"))
        XCTAssertEqual(draft.sourceText, text)
        XCTAssertTrue(draft.notes.hasSuffix(text))
        XCTAssertNil(draft.due)
    }
    func testHugeSingleGraphemeStillHasABoundedTitleAndFullNotes() throws {
        let text = "a" + String(repeating: "\u{0301}", count: 2000)
        let draft = try proposal(text)
        XCTAssertLessThanOrEqual(draft.title.utf8.count, 1000)
        XCTAssertEqual(draft.title, "Review meeting passage")
        XCTAssertTrue(draft.notes.hasSuffix(text))
    }
    func testEmptyPassageDoesNotCreateDraft() {
        XCTAssertNil(MeetingTaskDraft.make(text: " \n\t ", timestamp: "00:00:00", source: "Microphone", sessionTitle: "Meeting", listID: ""))
    }
    func testMeetingOriginSurvivesCodingAndOlderDraftsRemainDecodable() throws {
        let original = try proposal("Do not send this tomorrow")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TaskDraft.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertFalse(decoded.permitsCloudAssistance)
        var oldPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        oldPayload.removeValue(forKey: "origin")
        let old = try JSONDecoder().decode(TaskDraft.self, from: JSONSerialization.data(withJSONObject: oldPayload))
        XCTAssertNil(old.origin)
        XCTAssertTrue(old.permitsCloudAssistance)
    }
    func testReviewAcknowledgementDoesNotInventADateOrSaveAnything() throws {
        var draft = try proposal("Call Sam tomorrow at 10:30")
        draft.reviewAcknowledged = true
        XCTAssertTrue(draft.canSave)
        XCTAssertNil(draft.due)
        XCTAssertEqual(draft.alarm, .off)
    }
    func testExplicitAISuggestionKeepsProvenanceAndCannotInferAnArchivedRelativeDate() throws {
        let original = try proposal("Call Sam tomorrow at 10:30")
        let suggested = TaskDraft(title: "Call Sam", notes: "Ask about the design review.",
                                  due: TaskDue(year: 2099, month: 1, day: 2, hour: 10, minute: 30),
                                  sourceText: "Changed source")
        let result = MeetingTaskDraft.preservingContext(in: suggested, from: original)
        XCTAssertEqual(result.title, "Call Sam")
        XCTAssertNil(result.due)
        XCTAssertEqual(result.sourceText, original.sourceText)
        XCTAssertTrue(result.notes.hasPrefix(original.notes))
        XCTAssertTrue(result.notes.contains("Ask about the design review."))
        XCTAssertTrue(result.needsReview)
        XCTAssertEqual(result.alarm, .off)
    }
    func testExplicitlyChosenMeetingDateSurvivesALaterAISuggestion() throws {
        var original = try proposal("Call Sam tomorrow")
        original.due = TaskDue(year: 2026, month: 11, day: 6, hour: nil, minute: nil)
        let result = MeetingTaskDraft.preservingContext(in: TaskDraft(title: "Call Sam"), from: original)
        XCTAssertEqual(result.due, original.due)
        XCTAssertEqual(result.notes, original.notes)
        XCTAssertTrue(result.needsReview)
    }
    func testStagingDoesNotCallRemindersAndCannotOverwriteAnExistingDraft() throws {
        let (store, repository, defaults, domain) = makeStore()
        defer { defaults.removePersistentDomain(forName: domain) }
        let value = try proposal("Bring the updated notes tomorrow")
        XCTAssertTrue(store.stageMeetingDraft(value))
        XCTAssertEqual(store.draft, value)
        XCTAssertEqual(repository.calls, 0)
        let other = try proposal("A different meeting passage")
        XCTAssertFalse(store.stageMeetingDraft(other))
        XCTAssertEqual(store.draft, value)
        XCTAssertEqual(repository.calls, 0)
    }
    func testExplicitReplacementRequiresTheExactApprovedSnapshot() throws {
        let (store, repository, defaults, domain) = makeStore()
        defer { defaults.removePersistentDomain(forName: domain) }
        let original = try proposal("Keep this draft")
        let replacement = try proposal("New passage")
        store.draft = original
        store.draft?.notes += " An unsaved change."
        XCTAssertFalse(store.stageMeetingDraft(replacement, replacing: original))
        XCTAssertTrue(store.draft?.notes.hasSuffix("An unsaved change.") == true)
        let approved = try XCTUnwrap(store.draft)
        XCTAssertTrue(store.stageMeetingDraft(replacement, replacing: approved))
        XCTAssertEqual(store.draft, replacement)
        XCTAssertEqual(repository.calls, 0)
    }
    private func makeStore() -> (TaskBoardStore, MeetingTaskRepositorySpy, UserDefaults, String) {
        let name = "HeyNotchTests.meetingTask.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let repository = MeetingTaskRepositorySpy()
        return (TaskBoardStore(repository: repository, defaults: defaults), repository, defaults, name)
    }
}

@MainActor
private final class MeetingTaskRepositorySpy: TaskRepository {
    var calls = 0
    func requestAccess() async throws { calls += 1 }
    func lists() throws -> [TaskList] { calls += 1; return [] }
    func fetch() async throws -> [ReminderTask] { calls += 1; return [] }
    func save(_ draft: TaskDraft) async throws -> String { calls += 1; return "unexpected" }
    func complete(_ id: String, completed: Bool) throws { calls += 1 }
    func delete(_ id: String) throws { calls += 1 }
}
