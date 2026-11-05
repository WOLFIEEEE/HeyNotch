import XCTest

@MainActor
private final class NoticeTransport: MeetingNotificationTransport {
    var allowed = true
    var fail = false
    var hold = false
    var resume: CheckedContinuation<Void, Never>?
    var added: [String] = []
    var removed: [String] = []
    func canShowAlerts() async -> Bool { allowed }
    func add(identifier: String, activity: MeetingActivity, token: UUID) async throws {
        added.append(identifier)
        if hold { await withCheckedContinuation { resume = $0 } }
        if fail { throw NSError(domain: "test", code: 1) }
    }
    func remove(identifiers: [String]) { removed += identifiers }
}

@MainActor
final class MeetingNotificationTests: XCTestCase {
    let activity = MeetingActivity(microphoneApps: [.init(id: "test.call", name: "Test Call")])
    func testDisabledAndDeniedNotificationsFallBackWithoutSubmission() async {
        let transport = NoticeTransport(); let service = MeetingNotificationService(transport: transport)
        let disabled = await service.deliver(activity, token: UUID(), enabled: false)
        XCTAssertFalse(disabled); XCTAssertTrue(transport.added.isEmpty)
        transport.allowed = false
        let denied = await service.deliver(activity, token: UUID(), enabled: true)
        XCTAssertFalse(denied); XCTAssertTrue(transport.added.isEmpty)
    }
    func testSubmissionAndExplicitClearRemoveOnlyOwnedRequest() async {
        let transport = NoticeTransport(); let service = MeetingNotificationService(transport: transport)
        let token = UUID(); let id = MeetingNotificationService.prefix + token.uuidString
        let accepted = await service.deliver(activity, token: token, enabled: true)
        XCTAssertTrue(accepted); XCTAssertEqual(transport.added, [id])
        service.clear(); XCTAssertEqual(transport.removed, [id])
    }
    func testDeliveryFailureFallsBackAndCleansUpRequest() async {
        let transport = NoticeTransport(); transport.fail = true
        let service = MeetingNotificationService(transport: transport)
        let accepted = await service.deliver(activity, token: UUID(), enabled: true)
        XCTAssertFalse(accepted); XCTAssertEqual(transport.removed, transport.added)
    }
    func testLateDeliveryAfterDismissalIsRemoved() async {
        let transport = NoticeTransport(); transport.hold = true
        let service = MeetingNotificationService(transport: transport)
        let task = Task { await service.deliver(activity, token: UUID(), enabled: true) }
        while transport.resume == nil { await Task.yield() }
        service.clear(); transport.resume?.resume(); transport.resume = nil
        let accepted = await task.value
        XCTAssertFalse(accepted); XCTAssertEqual(transport.removed.last, transport.added.last)
    }
    func testLateOldRequestCannotRemoveNewNotification() async {
        let transport = NoticeTransport(); transport.hold = true
        let service = MeetingNotificationService(transport: transport)
        let old = Task { await service.deliver(activity, token: UUID(), enabled: true) }
        while transport.resume == nil { await Task.yield() }
        let oldResume = transport.resume; transport.resume = nil; transport.hold = false
        let newToken = UUID(); let id = MeetingNotificationService.prefix + newToken.uuidString
        let accepted = await service.deliver(activity, token: newToken, enabled: true)
        XCTAssertTrue(accepted)
        oldResume?.resume(); let oldAccepted = await old.value
        XCTAssertFalse(oldAccepted); XCTAssertFalse(transport.removed.contains(id))
    }
}
