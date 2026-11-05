import XCTest

final class NotchDragPolicyTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let closed = CGSize(width: 185, height: 32)
    private let point = CGPoint(x: 756, y: 960)
    private var region: CGRect { NotchDragPolicy.region(screenFrame: screen, closedSize: closed) }
    private func content(_ count: Int = 11, supported: Bool = true, task: Bool = false) -> NotchDragPolicy.Content {
        .init(changeCount: count, hasSupportedType: supported, isTaskMove: task)
    }
    private func entered(_ policy: inout NotchDragPolicy) throws -> UUID {
        policy.mouseDown(changeCount: 10)
        guard case .entered(let token) = policy.update(content: content(), primaryButtonDown: true,
                                                       point: point, region: region) else {
            XCTFail("A fresh supported drag near the notch should enter")
            throw NSError(domain: "NotchDragPolicyTests", code: 1)
        }
        return token
    }

    func testExpandedAreaStaysNearClosedNotchInsteadOfFuturePanel() {
        XCTAssertEqual(region, CGRect(x: 639.5, y: 926, width: 233, height: 56))
        let oldPanel = CGRect(x: 436, y: 792, width: 640, height: 190)
        for farPoint in [CGPoint(x: 756, y: 850), CGPoint(x: 500, y: 960)] {
            XCTAssertTrue(oldPanel.contains(farPoint))
            XCTAssertFalse(region.contains(farPoint))
            var policy = NotchDragPolicy()
            policy.mouseDown(changeCount: 10)
            XCTAssertNil(policy.update(content: content(), primaryButtonDown: true,
                                       point: farPoint, region: region))
        }
    }

    func testOffsetDisplaysUseGlobalAppKitCoordinates() {
        for offset in [CGPoint(x: -1512, y: 200), CGPoint(x: 0, y: -982), CGPoint(x: 1512, y: 982)] {
            let otherScreen = screen.offsetBy(dx: offset.x, dy: offset.y)
            let otherRegion = NotchDragPolicy.region(screenFrame: otherScreen, closedSize: closed)
            XCTAssertEqual(otherRegion, region.offsetBy(dx: offset.x, dy: offset.y))
            XCTAssertTrue(otherRegion.contains(CGPoint(x: point.x + offset.x, y: point.y + offset.y)))
            XCTAssertFalse(otherRegion.contains(point))
        }
    }

    func testExpansionDoesNotCrossDisplayEdgesAndZeroMeansVisibleNotchOnly() {
        let small = CGRect(x: -200, y: -50, width: 200, height: 50)
        let expanded = NotchDragPolicy.region(screenFrame: small, closedSize: CGSize(width: 190, height: 40))
        XCTAssertEqual(expanded, small)
        XCTAssertEqual(NotchDragPolicy.region(screenFrame: screen, closedSize: closed, expansion: 0),
                       CGRect(x: 663.5, y: 950, width: 185, height: 32))
    }

    func testOldPasteboardAndMouseMovementCannotStartContentDrag() {
        var policy = NotchDragPolicy()
        XCTAssertNil(policy.update(content: content(), primaryButtonDown: true, point: point, region: region))
        policy.mouseDown(changeCount: 11)
        XCTAssertNil(policy.update(content: content(), primaryButtonDown: true, point: point, region: region))
        XCTAssertNil(policy.update(content: content(12, supported: false), primaryButtonDown: true, point: point, region: region))
        XCTAssertNil(policy.update(content: content(12), primaryButtonDown: false, point: point, region: region))
    }

    func testSupportedDragEntersOnceUntilItLeaves() throws {
        var policy = NotchDragPolicy()
        let token = try entered(&policy)
        XCTAssertTrue(policy.canDeliver(token, content: content(), primaryButtonDown: true, point: point, region: region))
        for _ in 0..<20 {
            XCTAssertNil(policy.update(content: content(), primaryButtonDown: true, point: point, region: region))
        }
        XCTAssertEqual(policy.update(content: content(), primaryButtonDown: true,
                                     point: CGPoint(x: 756, y: 400), region: region), .exited)
        guard case .entered(let newToken) = policy.update(content: content(), primaryButtonDown: true,
                                                          point: point, region: region) else { return XCTFail("Re-entry expected") }
        XCTAssertNotEqual(newToken, token)
        XCTAssertFalse(policy.canDeliver(token, content: content(), primaryButtonDown: true, point: point, region: region))
    }

    func testPointerPinnedToPhysicalTopEdgeCanEnter() {
        var policy = NotchDragPolicy()
        policy.mouseDown(changeCount: 10)
        guard case .entered = policy.update(content: content(), primaryButtonDown: true,
                                             point: CGPoint(x: screen.midX, y: screen.maxY), region: region) else {
            return XCTFail("The screen's top edge is an intended drag target")
        }
    }

    func testQueuedOpeningRechecksCurrentPointerWithoutNeedingExitEvent() throws {
        var policy = NotchDragPolicy()
        let token = try entered(&policy)
        XCTAssertFalse(policy.canDeliver(token, content: content(), primaryButtonDown: true,
                                         point: CGPoint(x: 756, y: 400), region: region))
    }

    func testQueuedOpeningRechecksButtonReleaseWithoutNeedingMouseUpEvent() throws {
        var policy = NotchDragPolicy()
        let token = try entered(&policy)
        XCTAssertFalse(policy.canDeliver(token, content: content(), primaryButtonDown: false, point: point, region: region))
        XCTAssertEqual(policy.update(content: content(), primaryButtonDown: false, point: point, region: region), .exited)
        XCTAssertNil(policy.update(content: content(), primaryButtonDown: true, point: point, region: region))
    }

    func testChangedOrUnsupportedPasteboardCannotDeliverQueuedOpening() throws {
        var policy = NotchDragPolicy()
        let token = try entered(&policy)
        for changed in [content(12), content(supported: false), content(task: true)] {
            XCTAssertFalse(policy.canDeliver(token, content: changed, primaryButtonDown: true, point: point, region: region))
        }
    }

    func testTaskMoveIsExcludedBeforeAndAfterDragLatches() throws {
        var policy = NotchDragPolicy()
        policy.mouseDown(changeCount: 10)
        XCTAssertNil(policy.update(content: content(task: true), primaryButtonDown: true, point: point, region: region))
        let token = try entered(&policy)
        XCTAssertEqual(policy.update(content: content(task: true), primaryButtonDown: true, point: point, region: region), .exited)
        XCTAssertFalse(policy.canDeliver(token, content: content(), primaryButtonDown: true, point: point, region: region))
    }

    func testEndOrMonitorTeardownInvalidatesPendingOpening() throws {
        var policy = NotchDragPolicy()
        let token = try entered(&policy)
        XCTAssertEqual(policy.end(), .exited)
        XCTAssertNil(policy.end())
        XCTAssertFalse(policy.canDeliver(token, content: content(), primaryButtonDown: true, point: point, region: region))
        let replacement = try entered(&policy)
        XCTAssertNotEqual(token, replacement)
        XCTAssertFalse(policy.canDeliver(token, content: content(), primaryButtonDown: true, point: point, region: region))
    }

    func testNewMouseDownInvalidatesPreviousGestureEvenWhenReleaseWasMissed() throws {
        var policy = NotchDragPolicy()
        let token = try entered(&policy)
        policy.mouseDown(changeCount: 11)
        XCTAssertFalse(policy.canDeliver(token, content: content(), primaryButtonDown: true, point: point, region: region))
        XCTAssertNil(policy.update(content: content(), primaryButtonDown: true, point: point, region: region))
    }

    func testInvalidGeometryCannotActivate() {
        XCTAssertTrue(NotchDragPolicy.region(screenFrame: screen, closedSize: .zero).isNull)
        XCTAssertTrue(NotchDragPolicy.region(screenFrame: screen, closedSize: closed, expansion: .nan).isNull)
        for badPoint in [CGPoint(x: CGFloat.nan, y: 960), CGPoint(x: 756, y: CGFloat.infinity)] {
            var policy = NotchDragPolicy()
            policy.mouseDown(changeCount: 10)
            XCTAssertNil(policy.update(content: content(), primaryButtonDown: true, point: badPoint, region: region))
        }
    }
}
