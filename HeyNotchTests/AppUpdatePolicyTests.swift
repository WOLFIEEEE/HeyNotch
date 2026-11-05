import Foundation
import XCTest

final class AppUpdatePolicyTests: XCTestCase {
    private var releaseConfiguration: [String: Any] {
        [
            "HeyNotchUpdatesEnabled": true,
            "SUFeedURL": "https://WOLFIEEEE.github.io/HeyNotch/appcast.xml",
            "SUPublicEDKey": Data(repeating: 42, count: 32).base64EncodedString(),
        ]
    }

    func testValidForkConfigurationCanEnableUpdates() {
        XCTAssertTrue(AppUpdatePolicy(infoDictionary: releaseConfiguration).allowsUpdates)
    }

    func testDisabledBuildCannotBeEnabledBySparklePreferences() {
        var configuration = releaseConfiguration
        configuration["HeyNotchUpdatesEnabled"] = false
        configuration["SUEnableAutomaticChecks"] = true
        configuration["SUAutomaticallyUpdate"] = true
        XCTAssertFalse(AppUpdatePolicy(infoDictionary: configuration).allowsUpdates)
    }

    func testMissingOptInKeepsUpdatesDisabled() {
        var configuration = releaseConfiguration
        configuration.removeValue(forKey: "HeyNotchUpdatesEnabled")
        XCTAssertFalse(AppUpdatePolicy(infoDictionary: configuration).allowsUpdates)
        XCTAssertFalse(AppUpdatePolicy(infoDictionary: [:]).allowsUpdates)
    }

    func testFeedMustBelongToTheFork() {
        let invalidFeeds = [
            "http://WOLFIEEEE.github.io/HeyNotch/appcast.xml",
            "https://example.com/HeyNotch/appcast.xml",
            "https://WOLFIEEEE.github.io/another-app/appcast.xml",
            "https://WOLFIEEEE.github.io.evil.example/HeyNotch/appcast.xml",
            "https://WOLFIEEEE.github.io@evil.example/HeyNotch/appcast.xml",
            "https://user@WOLFIEEEE.github.io/HeyNotch/appcast.xml",
            "https://WOLFIEEEE.github.io:8080/HeyNotch/appcast.xml",
            "https://WOLFIEEEE.github.io/HeyNotch/appcast.xml?redirect=other",
            "https://WOLFIEEEE.github.io/HeyNotch/appcast.xml#other",
            "not a URL",
        ]
        for feed in invalidFeeds {
            var configuration = releaseConfiguration
            configuration["SUFeedURL"] = feed
            XCTAssertFalse(AppUpdatePolicy(infoDictionary: configuration).allowsUpdates, feed)
        }
    }

    func testMissingFeedKeepsUpdatesDisabled() {
        var configuration = releaseConfiguration
        configuration.removeValue(forKey: "SUFeedURL")
        XCTAssertFalse(AppUpdatePolicy(infoDictionary: configuration).allowsUpdates)
    }

    func testMissingOrMalformedPublicKeyKeepsUpdatesDisabled() {
        var configuration = releaseConfiguration
        configuration.removeValue(forKey: "SUPublicEDKey")
        XCTAssertFalse(AppUpdatePolicy(infoDictionary: configuration).allowsUpdates)

        for key in ["", "not base64", Data(repeating: 42, count: 31).base64EncodedString(),
                    Data(repeating: 42, count: 33).base64EncodedString()] {
            configuration["SUPublicEDKey"] = key
            XCTAssertFalse(AppUpdatePolicy(infoDictionary: configuration).allowsUpdates)
        }
    }
}
