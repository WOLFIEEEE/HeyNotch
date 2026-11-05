import Foundation
import Security
import XCTest

final class XPCPeerTrustTests: XCTestCase {
    func testSignedPeerProducesAValidRequirementForItsActualIdentity() throws {
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let text = try XCTUnwrap(XPCPeerTrust.requirement(for: textEdit, identifier: "com.apple.TextEdit"))
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess)
        XCTAssertNotNil(requirement)
        XCTAssertNil(XPCPeerTrust.requirement(for: textEdit, identifier: XPCPeerTrust.appIdentifier))
    }

    func testCopiedBundleIdentifierWithoutASignatureIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HeyNotch-peer-test-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": XPCPeerTrust.appIdentifier,
                                    "CFBundlePackageType": "APPL", "CFBundleExecutable": "FakeHeyNotch"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        XCTAssertNil(XPCPeerTrust.requirement(for: root, identifier: XPCPeerTrust.appIdentifier))
    }
}
