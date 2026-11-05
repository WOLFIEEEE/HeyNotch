import XCTest

final class NotchLayoutTests: XCTestCase {
    func testExplicitTasksWinsOverPreviouslyUsedMusicOrShelf() {
        XCTAssertEqual(NotchLandingPage.tasks.resolve(lastUsed: .home, shelfEnabled: true), .tasks)
        XCTAssertEqual(NotchLandingPage.tasks.resolve(lastUsed: .shelf, shelfEnabled: true), .tasks)
    }
    func testEachOpeningPreferenceAndDisabledShelfFallback() {
        XCTAssertEqual(NotchLandingPage.home.resolve(lastUsed: .tasks, shelfEnabled: true), .home)
        XCTAssertEqual(NotchLandingPage.shelf.resolve(lastUsed: .tasks, shelfEnabled: true), .shelf)
        XCTAssertEqual(NotchLandingPage.lastUsed.resolve(lastUsed: .home, shelfEnabled: true), .home)
        XCTAssertEqual(NotchLandingPage.lastUsed.resolve(lastUsed: .tasks, shelfEnabled: true), .tasks)
        XCTAssertEqual(NotchLandingPage.shelf.resolve(lastUsed: .home, shelfEnabled: false), .tasks)
        XCTAssertEqual(NotchLandingPage.lastUsed.resolve(lastUsed: .shelf, shelfEnabled: false), .tasks)
    }
    func testMusicAndShelfKeepCompactSizeRegardlessOfTaskCount() {
        for page in [NotchViews.home, .shelf] {
            XCTAssertEqual(NotchLayoutPolicy.openSize(page: page, tallestColumnCount: 100, screenWidth: 1512, availableHeight: 900), CGSize(width: 640, height: 190))
        }
    }
    func testTaskBoardGrowsWithCardsThenScrollsAtCeiling() {
        let empty = size(0), two = size(2), three = size(3), many = size(500)
        XCTAssertEqual(empty.width, 800)
        XCTAssertGreaterThan(two.height, empty.height)
        XCTAssertGreaterThan(three.height, two.height)
        XCTAssertEqual(many.height, 500)
        XCTAssertEqual(size(500, maximum: 320).height, 320)
        XCTAssertEqual(size(500, maximum: 600).height, 600)
    }
    func testAllSizesFitSmallDisplays() {
        for page in NotchViews.allCases {
            let value = NotchLayoutPolicy.openSize(page: page, tallestColumnCount: 100, screenWidth: 500, availableHeight: 280)
            XCTAssertLessThanOrEqual(value.width, 468)
            XCTAssertLessThanOrEqual(value.height, 256)
            XCTAssertGreaterThan(value.width, 0)
            XCTAssertGreaterThan(value.height, 0)
        }
    }
    func testInvalidSizingValuesCannotCreateNonfiniteFrames() {
        let value = NotchLayoutPolicy.openSize(page: .tasks, tallestColumnCount: -5, screenWidth: .nan, availableHeight: .infinity, maximumTaskHeight: .nan)
        XCTAssertEqual(value, CGSize(width: 800, height: 290))
        XCTAssertEqual(size(500, maximum: -100).height, 320)
        XCTAssertEqual(size(500, maximum: 99999).height, 600)
    }
    private func size(_ rows: Int, maximum: Double = 500) -> CGSize {
        NotchLayoutPolicy.openSize(page: .tasks, tallestColumnCount: rows, screenWidth: 1512, availableHeight: 900, maximumTaskHeight: maximum)
    }
}
