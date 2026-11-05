import XCTest

final class NotchInteractionGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let closed = CGSize(width: 185, height: 32)

    func testClosedNotchDoesNotUseTheLargerTransparentPanelAsHoverArea() {
        let point = CGPoint(x: 756, y: 850)
        XCTAssertTrue(NotchInteractionGeometry.contains(point: point, screenFrame: screen,
                                                       size: CGSize(width: 640, height: 210)))
        XCTAssertFalse(NotchInteractionGeometry.contains(point: point, screenFrame: screen, size: closed))
        XCTAssertFalse(NotchInteractionGeometry.contains(point: CGPoint(x: 500, y: 970),
                                                        screenFrame: screen, size: closed))
    }

    func testHoverRecheckUsesCurrentPointerRatherThanTheEntryPosition() {
        let entered = CGPoint(x: 756, y: 970)
        let afterDelay = CGPoint(x: 1200, y: 300)
        XCTAssertTrue(NotchInteractionGeometry.contains(point: entered, screenFrame: screen, size: closed))
        XCTAssertFalse(NotchInteractionGeometry.contains(point: afterDelay, screenFrame: screen, size: closed))
    }

    func testTopEdgeAndOpenTaskBoardRemainReachable() {
        XCTAssertTrue(NotchInteractionGeometry.contains(point: CGPoint(x: 756, y: 982), screenFrame: screen, size: closed))
        XCTAssertTrue(NotchInteractionGeometry.contains(point: CGPoint(x: 1000, y: 500), screenFrame: screen,
                                                       size: CGSize(width: 800, height: 500)))
    }

    func testDisplayOffsetsIncludingScreensToTheLeftAndAbove() {
        for origin in [CGPoint(x: -1920, y: 100), CGPoint(x: 1512, y: -500), CGPoint(x: 0, y: 982)] {
            let frame = CGRect(origin: origin, size: CGSize(width: 1920, height: 1080))
            let inside = CGPoint(x: frame.midX, y: frame.maxY - 12)
            XCTAssertTrue(NotchInteractionGeometry.contains(point: inside, screenFrame: frame, size: closed))
            XCTAssertFalse(NotchInteractionGeometry.contains(point: CGPoint(x: 756, y: 970), screenFrame: frame, size: closed))
        }
    }

    func testHiddenOrInvalidFramesCannotActivate() {
        for size in [CGSize.zero, CGSize(width: -1, height: 32), CGSize(width: CGFloat.nan, height: 32),
                     CGSize(width: 185, height: CGFloat.infinity)] {
            XCTAssertFalse(NotchInteractionGeometry.contains(point: CGPoint(x: 756, y: 970), screenFrame: screen, size: size))
        }
        XCTAssertFalse(NotchInteractionGeometry.contains(point: CGPoint(x: CGFloat.nan, y: 970), screenFrame: screen, size: closed))
        XCTAssertEqual(NotchInteractionGeometry.screenRect(screenFrame: CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10), size: closed), .zero)
    }

    func testSmallScreenClampsRegionToThePhysicalDisplay() {
        let frame = CGRect(x: -100, y: -200, width: 80, height: 60)
        XCTAssertEqual(NotchInteractionGeometry.screenRect(screenFrame: frame, size: CGSize(width: 800, height: 500)), frame)
    }

    func testHostingCanvasContainsAllOpenSizesThroughoutCloseAndReopen() {
        for screenSize in [CGSize(width: 1512, height: 982), CGSize(width: 500, height: 280)] {
            let available = Double(screenSize.height - 24)
            let canvas = NotchLayoutPolicy.hostingSize(screenSize: screenSize, availableHeight: available)
            for page in NotchViews.allCases {
                for rows in [0, 2, 5, 100] {
                    let open = NotchLayoutPolicy.openSize(page: page, tallestColumnCount: rows,
                                                         screenWidth: Double(screenSize.width), availableHeight: available,
                                                         maximumTaskHeight: 600)
                    XCTAssertGreaterThanOrEqual(canvas.width, open.width)
                    XCTAssertGreaterThanOrEqual(canvas.height, open.height)
                }
            }
            // No notch state/current content size input can shrink the native
            // canvas while SwiftUI's closing presentation is still drawing.
            XCTAssertEqual(canvas, NotchLayoutPolicy.hostingSize(screenSize: screenSize, availableHeight: available))
            XCTAssertLessThanOrEqual(canvas.width, screenSize.width)
            XCTAssertLessThanOrEqual(canvas.height, screenSize.height)
        }
    }

    func testInvalidDisplayDimensionsStillGiveFiniteHostingSize() {
        let size = NotchLayoutPolicy.hostingSize(screenSize: CGSize(width: CGFloat.nan, height: CGFloat.infinity), availableHeight: .nan)
        XCTAssertTrue(size.width.isFinite)
        XCTAssertTrue(size.height.isFinite)
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }
}
