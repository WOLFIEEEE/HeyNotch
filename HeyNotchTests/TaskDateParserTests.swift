import Foundation
import XCTest

final class TaskDateParserTests: XCTestCase {
    func testTaskLinksOnlyAcceptOneOperationID() {
        let id = UUID()
        XCTAssertEqual(TaskLink.operation(in: TaskLink.url(id)), id)
        XCTAssertNil(TaskLink.operation(in: URL(string: "https://task/\(id)")!))
        XCTAssertNil(TaskLink.operation(in: URL(string: "heynotch://task/not-a-uuid")!))
        XCTAssertNil(TaskLink.operation(in: URL(string: "heynotch://task/\(id)?action=delete")!))
        XCTAssertNil(TaskLink.operation(in: URL(string: "heynotch://task/other/\(id)")!))
    }
    private let utc = TimeZone(secondsFromGMT: 0)!
    private func parser(_ instant: String = "2026-11-05T08:00:00Z", zone: TimeZone? = nil) -> TaskDateParser {
        TaskDateParser(now: ISO8601DateFormatter().date(from: instant)!, calendar: Calendar(identifier: .gregorian),
                       locale: Locale(identifier: "en_US"), timeZone: zone ?? utc)
    }
    func testUndatedTaskStaysUndated() {
        let draft = parser().parse("buy milk")
        XCTAssertEqual(draft.title, "buy milk"); XCTAssertNil(draft.due); XCTAssertFalse(draft.needsReview)
    }
    func testAmbiguousClockTimeNeedsReviewAndDoesNotInventTime() {
        let draft = parser().parse("call the dentist tomorrow at 10")
        XCTAssertEqual(draft.due?.day, 6); XCTAssertFalse(draft.due?.hasTime ?? true)
        XCTAssertTrue(draft.needsReview); XCTAssertTrue(draft.title.contains("dentist"))
    }
    func testFirstOfNextMonthAndYearBoundary() {
        let draft = parser("2026-12-31T08:00:00Z").parse("pay rent on the 1st")
        XCTAssertEqual(draft.title, "pay rent"); XCTAssertEqual(draft.due, TaskDue(year: 2027, month: 1, day: 1))
    }
    func testThirtyFirstSkipsMonthsWithoutThatDay() {
        let draft = parser("2026-04-10T08:00:00Z").parse("pay rent on the 31st")
        XCTAssertEqual(draft.due?.month, 5); XCTAssertEqual(draft.due?.day, 31)
    }
    func testWeekdayPartOfDayRequiresReview() {
        let draft = parser().parse("email Sam Friday afternoon")
        XCTAssertEqual(draft.due?.day, 6); XCTAssertTrue(draft.needsReview); XCTAssertNil(draft.due?.hour)
    }
    func testRelativeHoursAreTimedAndUseInjectedClock() {
        let draft = parser().parse("check the oven in two hours")
        XCTAssertEqual(draft.title, "check the oven")
        XCTAssertEqual(draft.due?.hour, 10); XCTAssertEqual(draft.due?.minute, 0)
        XCTAssertFalse(draft.needsReview)
    }
    func testPossessiveWeekdayInTitleIsPreserved() {
        let draft = parser().parse("prepare Friday’s presentation tomorrow")
        XCTAssertEqual(draft.title, "prepare Friday’s presentation")
        XCTAssertEqual(draft.due?.day, 6); XCTAssertFalse(draft.needsReview)
    }
    func testExplicitAMPMAndNoDateDefaultsToNextOccurrence() {
        let draft = parser("2026-11-05T18:00:00Z").parse("call Sam at 5 pm")
        XCTAssertEqual(draft.title, "call Sam")
        XCTAssertEqual(draft.due?.day, 6); XCTAssertEqual(draft.due?.hour, 17)
    }
    func testRecurringTaskCannotSilentlyBecomeOneOff() {
        let draft = parser().parse("take medicine every day at 8")
        XCTAssertNil(draft.due); XCTAssertTrue(draft.needsReview); XCTAssertFalse(draft.canSave)
    }
    func testMultipleDatesRequireChoosingOne() {
        let draft = parser().parse("call Sam tomorrow or Friday")
        XCTAssertNil(draft.due); XCTAssertTrue(draft.needsReview)
    }
    func testISODateAndInvalidDate() {
        XCTAssertEqual(parser().parse("renew passport on 2027-02-01").due, TaskDue(year: 2027, month: 2, day: 1))
        XCTAssertTrue(parser().parse("renew passport on 2027-02-30").needsReview)
        XCTAssertTrue(parser().parse("renew passport on the 32nd").needsReview)
    }
    func testDSTMissingAndRepeatedTimesRequireReview() {
        let zone = TimeZone(identifier: "America/New_York")!
        let missing = parser("2027-03-13T16:00:00Z", zone: zone).parse("call Sam tomorrow at 2:30 am")
        XCTAssertTrue(missing.needsReview); XCTAssertNil(missing.due?.hour)
        let repeated = parser("2026-10-31T16:00:00Z", zone: zone).parse("call Sam tomorrow at 1:30 am")
        XCTAssertTrue(repeated.needsReview); XCTAssertNil(repeated.due?.hour)
    }
    func testUnicodeTitleIsNotCorruptedByCaseConversion() {
        let draft = parser().parse("İstanbul यात्रा tomorrow")
        XCTAssertEqual(draft.title, "İstanbul यात्रा"); XCTAssertEqual(draft.due?.day, 6)
    }
    func testDateOnlyAndTimedGrouping() {
        let now = parser().now
        func item(_ due: TaskDue?, completed: Bool = false) -> ReminderTask {
            ReminderTask(id: "fixture", title: "Task", notes: "", due: due, completed: completed, listID: "list", alarms: [], recurring: false)
        }
        let calendar = parser().calendar
        XCTAssertEqual(TaskSection.section(for: item(nil), now: now, calendar: calendar), .undated)
        XCTAssertEqual(TaskSection.section(for: item(TaskDue(year: 2026, month: 11, day: 5)), now: now, calendar: calendar), .today)
        XCTAssertEqual(TaskSection.section(for: item(TaskDue(year: 2026, month: 11, day: 4)), now: now, calendar: calendar), .overdue)
        XCTAssertEqual(TaskSection.section(for: item(nil, completed: true), now: now, calendar: calendar), .completed)
    }
    func testAIProposalsAlwaysRequireReviewAndValidateDates() throws {
        let good = #"{"title":"buy milk","notes":"","dueDate":null,"hasTime":false,"needsReview":false}"#
        let draft = try TaskAssistance.validate(good, source: "buy milk", now: parser().now, timeZone: utc)
        XCTAssertNil(draft.due); XCTAssertTrue(draft.needsReview)
        let invalid = #"{"title":"buy milk","notes":"","dueDate":"2027-02-30","hasTime":false,"needsReview":false}"#
        XCTAssertThrowsError(try TaskAssistance.validate(invalid, source: "buy milk", now: parser().now, timeZone: utc))
    }
}
