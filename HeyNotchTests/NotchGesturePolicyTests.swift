import XCTest

final class NotchGesturePolicyTests: XCTestCase {
    func testTaskContentScrollCannotCloseOrBecomeHeaderGestureMidway() {
        var policy = NotchGesturePolicy()
        let region = NotchGestureRegion.top(height: 32)
        let size = CGSize(width: 500, height: 500)
        let body = region.contains(CGPoint(x: 100, y: 200), in: size)
        let header = region.contains(CGPoint(x: 100, y: 16), in: size)
        XCTAssertTrue(policy.process(direction: .up, deltaX: 0, deltaY: -100, phase: .began,
                                     isEnabled: true, locationAllowed: body, activationThreshold: 20).isEmpty)
        XCTAssertTrue(policy.process(direction: .up, deltaX: 0, deltaY: -100, phase: .changed,
                                     isEnabled: true, locationAllowed: header, activationThreshold: 20).isEmpty)
        XCTAssertTrue(policy.finish().isEmpty)
    }

    func testClosedNotchOpensOnceAndRemainderDoesNotRearmAfterStateChange() {
        var policy = NotchGesturePolicy()
        var updates = policy.process(direction: .down, deltaX: 0, deltaY: 8, phase: .began,
                                     isEnabled: true, locationAllowed: true, activationThreshold: 20)
        updates += policy.process(direction: .down, deltaX: 0, deltaY: 12, phase: .changed,
                                  isEnabled: true, locationAllowed: true, activationThreshold: 20)
        updates += policy.process(direction: .down, deltaX: 0, deltaY: 50, phase: .changed,
                                  isEnabled: false, locationAllowed: true, activationThreshold: 20)
        updates += policy.process(direction: .down, deltaX: 0, deltaY: 50, phase: .changed,
                                  isEnabled: true, locationAllowed: true, activationThreshold: 20)
        XCTAssertEqual(updates.filter { $0.translation >= 20 }.count, 1)
        XCTAssertEqual(updates.last, .init(translation: 0, phase: .ended))
    }

    func testHeaderCloseLatchesAfterOneActivationUntilLift() {
        var policy = NotchGesturePolicy()
        var updates = policy.process(direction: .up, deltaX: 0, deltaY: -30, phase: .began,
                                     isEnabled: true, locationAllowed: true, activationThreshold: 20)
        for _ in 0..<10 {
            updates += policy.process(direction: .up, deltaX: 0, deltaY: -30, phase: .changed,
                                      isEnabled: true, locationAllowed: true, activationThreshold: 20)
        }
        updates += policy.process(direction: .up, deltaX: 0, deltaY: -100, phase: .ended,
                                  isEnabled: true, locationAllowed: true, activationThreshold: 20)
        XCTAssertEqual(updates, [.init(translation: 30, phase: .began), .init(translation: 0, phase: .ended)])
    }

    func testMomentumNeverActivatesEvenWithoutObservedPhysicalGesture() {
        var policy = NotchGesturePolicy()
        for phase in [NotchGesturePolicy.Phase.began, .changed, .ended, .unphased] {
            XCTAssertTrue(policy.process(direction: .up, deltaX: 0, deltaY: -200, phase: phase,
                                         isMomentum: true, isEnabled: true, locationAllowed: true,
                                         activationThreshold: 20).isEmpty)
        }
        XCTAssertTrue(policy.process(direction: .down, deltaX: 0, deltaY: 200, phase: .changed,
                                     isEnabled: true, locationAllowed: true, activationThreshold: 20).isEmpty)
    }

    func testEndAndCancelClearProgressAndPermitANewGesture() {
        for phase in [NotchGesturePolicy.Phase.ended, .cancelled] {
            var policy = NotchGesturePolicy()
            XCTAssertEqual(policy.process(direction: .up, deltaX: 0, deltaY: -8, phase: .began,
                                          isEnabled: true, locationAllowed: true, activationThreshold: 20),
                           [.init(translation: 8, phase: .began)])
            XCTAssertEqual(policy.process(direction: .up, deltaX: 0, deltaY: -100, phase: phase,
                                          isEnabled: true, locationAllowed: true, activationThreshold: 20),
                           [.init(translation: 0, phase: .ended)])
            XCTAssertEqual(policy.process(direction: .up, deltaX: 0, deltaY: -8, phase: .began,
                                          isEnabled: true, locationAllowed: true, activationThreshold: 20),
                           [.init(translation: 8, phase: .began)])
        }
    }

    func testDisabledStartCannotActivateWhenEnabledMidGesture() {
        var policy = NotchGesturePolicy()
        XCTAssertTrue(policy.process(direction: .up, deltaX: 0, deltaY: -40, phase: .began,
                                     isEnabled: false, locationAllowed: true, activationThreshold: 20).isEmpty)
        XCTAssertTrue(policy.process(direction: .up, deltaX: 0, deltaY: -40, phase: .changed,
                                     isEnabled: true, locationAllowed: true, activationThreshold: 20).isEmpty)
    }

    func testLeavingAllowedBoundsCancelsUntilNextStart() {
        var policy = NotchGesturePolicy()
        _ = policy.process(direction: .up, deltaX: 0, deltaY: -5, phase: .began,
                           isEnabled: true, locationAllowed: true, activationThreshold: 20)
        XCTAssertEqual(policy.process(direction: .up, deltaX: 0, deltaY: -30, phase: .changed,
                                      isEnabled: true, locationAllowed: false, activationThreshold: 20),
                       [.init(translation: 0, phase: .ended)])
        XCTAssertTrue(policy.process(direction: .up, deltaX: 0, deltaY: -30, phase: .changed,
                                     isEnabled: true, locationAllowed: true, activationThreshold: 20).isEmpty)
    }

    func testHorizontalAndDiagonalScrollingDoNotCloseNotch() {
        var policy = NotchGesturePolicy()
        XCTAssertTrue(policy.process(direction: .up, deltaX: 100, deltaY: -5, phase: .began,
                                     isEnabled: true, locationAllowed: true, activationThreshold: 20).isEmpty)
        XCTAssertTrue(policy.process(direction: .up, deltaX: 50, deltaY: -50, phase: .changed,
                                     isEnabled: true, locationAllowed: true, activationThreshold: 20).isEmpty)
        XCTAssertTrue(policy.finish().isEmpty)
    }

    func testWheelMouseUsesInactivityBoundaryAndOneActionPerBurst() {
        var policy = NotchGesturePolicy()
        var updates: [NotchGesturePolicy.Update] = []
        for _ in 0..<5 {
            updates += policy.process(direction: .up, deltaX: 0, deltaY: -1, phase: .unphased,
                                      isPrecise: false, isEnabled: true, locationAllowed: true,
                                      activationThreshold: 20)
        }
        XCTAssertEqual(updates.filter { $0.translation >= 20 }.count, 1)
        XCTAssertEqual(policy.finish(), [.init(translation: 0, phase: .ended)])
        XCTAssertEqual(policy.process(direction: .up, deltaX: 0, deltaY: -1, phase: .unphased,
                                      isPrecise: false, isEnabled: true, locationAllowed: true,
                                      activationThreshold: 20), [.init(translation: 8, phase: .began)])
    }

    func testReversingBeforeActivationResetsDistance() {
        var policy = NotchGesturePolicy()
        _ = policy.process(direction: .up, deltaX: 0, deltaY: -15, phase: .began,
                           isEnabled: true, locationAllowed: true, activationThreshold: 20)
        XCTAssertEqual(policy.process(direction: .up, deltaX: 0, deltaY: 5, phase: .changed,
                                      isEnabled: true, locationAllowed: true, activationThreshold: 20),
                       [.init(translation: 0, phase: .changed)])
        XCTAssertEqual(policy.process(direction: .up, deltaX: 0, deltaY: -10, phase: .changed,
                                      isEnabled: true, locationAllowed: true, activationThreshold: 20),
                       [.init(translation: 10, phase: .changed)])
    }

    func testRegionsExcludeOtherViewsAndInvalidCoordinates() {
        let size = CGSize(width: 200, height: 300)
        XCTAssertTrue(NotchGestureRegion.entireView.contains(CGPoint(x: 10, y: 200), in: size))
        XCTAssertFalse(NotchGestureRegion.top(height: 32).contains(CGPoint(x: 10, y: 32), in: size))
        XCTAssertFalse(NotchGestureRegion.entireView.contains(CGPoint(x: 200, y: 10), in: size))
        XCTAssertFalse(NotchGestureRegion.entireView.contains(CGPoint(x: -1, y: 10), in: size))
        XCTAssertFalse(NotchGestureRegion.entireView.contains(CGPoint(x: CGFloat.nan, y: 10), in: size))
        XCTAssertFalse(NotchGestureRegion.entireView.contains(CGPoint(x: 0, y: 0), in: .zero))
    }

    func testHorizontalMusicSwipeRetainsDirectionAndLatch() {
        var policy = NotchGesturePolicy()
        XCTAssertEqual(policy.process(direction: .left, deltaX: -30, deltaY: 1, phase: .began,
                                      isEnabled: true, locationAllowed: true, activationThreshold: 20),
                       [.init(translation: 30, phase: .began)])
        XCTAssertTrue(policy.process(direction: .left, deltaX: -30, deltaY: 1, phase: .changed,
                                     isEnabled: true, locationAllowed: true, activationThreshold: 20).isEmpty)
    }

    func testRejectedWheelBurstRemainsLockedUntilInactivity() {
        for disabled in [false, true] {
            var policy = NotchGesturePolicy()
            var inactivity = NotchWheelInactivity()
            XCTAssertFalse(inactivity.recordEvent(at: 100))
            XCTAssertTrue(policy.process(direction: .up, deltaX: 0, deltaY: -50, phase: .unphased,
                                         isEnabled: !disabled, locationAllowed: disabled,
                                         activationThreshold: 20).isEmpty)
            XCTAssertFalse(policy.needsInactivityEnd)
            // Enabling the modifier or moving into its header during this burst cannot arm it.
            XCTAssertFalse(inactivity.recordEvent(at: 100.1))
            XCTAssertTrue(policy.process(direction: .up, deltaX: 0, deltaY: -50, phase: .unphased,
                                         isEnabled: true, locationAllowed: true, activationThreshold: 20).isEmpty)
            XCTAssertFalse(policy.needsInactivityEnd)
            XCTAssertTrue(inactivity.recordEvent(at: 100.41))
            XCTAssertTrue(policy.finish().isEmpty)
            XCTAssertEqual(policy.process(direction: .up, deltaX: 0, deltaY: -50, phase: .unphased,
                                          isEnabled: true, locationAllowed: true, activationThreshold: 20),
                           [.init(translation: 50, phase: .began)])
        }
    }

    func testSubthresholdWheelDistanceDoesNotCarryAcrossIdleGap() {
        var policy = NotchGesturePolicy()
        var inactivity = NotchWheelInactivity()
        XCTAssertFalse(inactivity.recordEvent(at: 100))
        XCTAssertTrue(policy.process(direction: .up, deltaX: 0, deltaY: -2, phase: .unphased,
                                     isEnabled: true, locationAllowed: true).isEmpty)
        XCTAssertFalse(policy.needsInactivityEnd)
        XCTAssertTrue(inactivity.recordEvent(at: 100.31))
        XCTAssertTrue(policy.finish().isEmpty)
        XCTAssertTrue(policy.process(direction: .up, deltaX: 0, deltaY: -2, phase: .unphased,
                                     isEnabled: true, locationAllowed: true).isEmpty)
        XCTAssertFalse(inactivity.recordEvent(at: 100.4))
        XCTAssertEqual(policy.process(direction: .up, deltaX: 0, deltaY: -2, phase: .unphased,
                                      isEnabled: true, locationAllowed: true),
                       [.init(translation: 4, phase: .began)])
        XCTAssertTrue(policy.needsInactivityEnd)
    }

    func testWheelDeadlineMovesWithoutEndingAtThePreviousDeadline() {
        var inactivity = NotchWheelInactivity()
        XCTAssertFalse(inactivity.recordEvent(at: 100))
        XCTAssertEqual(inactivity.remaining(at: 100.2)!, 0.1, accuracy: 0.000_001)
        XCTAssertFalse(inactivity.recordEvent(at: 100.2))
        XCTAssertEqual(inactivity.remaining(at: 100.31)!, 0.19, accuracy: 0.000_001)
        XCTAssertFalse(inactivity.recordEvent(at: 100.49))
        XCTAssertEqual(inactivity.remaining(at: 100.8), 0)
        XCTAssertTrue(inactivity.recordEvent(at: 100.8))
    }

    func testActivatedWheelGestureStillNeedsOneFinalFeedbackReset() {
        var policy = NotchGesturePolicy()
        _ = policy.process(direction: .up, deltaX: 0, deltaY: -50, phase: .unphased,
                           isEnabled: true, locationAllowed: true, activationThreshold: 20)
        XCTAssertTrue(policy.needsInactivityEnd)
        XCTAssertTrue(policy.process(direction: .up, deltaX: 0, deltaY: -50, phase: .unphased,
                                     isEnabled: true, locationAllowed: true, activationThreshold: 20).isEmpty)
        XCTAssertTrue(policy.needsInactivityEnd)
        XCTAssertEqual(policy.finish(), [.init(translation: 0, phase: .ended)])
        XCTAssertFalse(policy.needsInactivityEnd)
    }

    func testWheelDeadlineClearsWhenPhasedInputOrTeardownTakesOver() {
        var inactivity = NotchWheelInactivity()
        _ = inactivity.recordEvent(at: 100)
        inactivity.reset()
        XCTAssertNil(inactivity.remaining(at: 100.1))
        XCTAssertFalse(inactivity.recordEvent(at: 101))
    }
}
