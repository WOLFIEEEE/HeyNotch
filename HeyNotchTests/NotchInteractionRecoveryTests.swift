import XCTest

final class NotchInteractionRecoveryTests: XCTestCase {
    func testShortcutTimeoutKeepsAnActiveBatteryPopoverOpenUntilDismissed() {
        var state = idleOpenState
        state.popoverActive = true
        XCTAssertFalse(state.permitsClose, "The pointer can be outside the notch while using its popover.")
        state.popoverActive = false
        XCTAssertTrue(state.permitsClose)
    }

    func testEveryActiveInteractionPreventsAutomaticClosing() {
        for key in [\NotchAutoCloseState.pointerInside, \.menuActive, \.popoverActive,
                    \.sharingActive, \.dropTargeted] {
            var state = idleOpenState
            state[keyPath: key] = true
            XCTAssertFalse(state.permitsClose)
        }
        var closed = idleOpenState
        closed.isOpen = false
        XCTAssertFalse(closed.permitsClose)
    }

    func testSwitchingToMusicWithHiddenTabsStillProvidesTasksNavigation() {
        XCTAssertEqual(NotchNavigationPolicy.presentation(alwaysShowTabs: false, shelfEmpty: true, page: .tasks), .tabs)
        XCTAssertEqual(NotchNavigationPolicy.presentation(alwaysShowTabs: false, shelfEmpty: true, page: .home), .menu)
        for shelfEnabled in [false, true] {
            let pages = NotchNavigationPolicy.pages(shelfEnabled: shelfEnabled)
            XCTAssertTrue(pages.contains(.tasks))
            XCTAssertTrue(pages.contains(.home))
            XCTAssertEqual(pages.contains(.shelf), shelfEnabled)
        }
        // Reopening the last-used Music page must also retain its menu.
        let reopened = NotchLandingPage.lastUsed.resolve(lastUsed: .home, shelfEnabled: false)
        XCTAssertEqual(NotchNavigationPolicy.presentation(alwaysShowTabs: false, shelfEmpty: true, page: reopened), .menu)
    }

    func testAlwaysVisibleTabsAndOccupiedShelfKeepTheirExistingPresentation() {
        for page in NotchViews.allCases {
            XCTAssertEqual(NotchNavigationPolicy.presentation(alwaysShowTabs: true, shelfEmpty: true, page: page), .tabs)
            XCTAssertEqual(NotchNavigationPolicy.presentation(alwaysShowTabs: false, shelfEmpty: false, page: page), .tabs)
        }
    }

    private var idleOpenState: NotchAutoCloseState {
        NotchAutoCloseState(isOpen: true, pointerInside: false, menuActive: false,
                            popoverActive: false, sharingActive: false, dropTargeted: false)
    }
}
