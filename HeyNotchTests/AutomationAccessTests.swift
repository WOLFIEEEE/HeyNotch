import Foundation
import Darwin
import XCTest

@MainActor
final class AutomationAccessTests: XCTestCase {
    private func fixture(_ body: (AutomationAccessStore, FakeAutomationSecrets, UserDefaults) throws -> Void) rethrows {
        let domain = "HeyNotchTests.automation-access." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let secrets = FakeAutomationSecrets()
        try body(AutomationAccessStore(defaults: defaults, secretStore: secrets), secrets, defaults)
    }

    func testDefaultDisabledAndMetadataNeverContainsToken() throws {
        try fixture { store, secrets, defaults in
            XCTAssertFalse(store.enabled)
            XCTAssertEqual(secrets.reads, 0)
            let grant = try store.createGrant(name: "  Test client  ", listIDs: ["work"], canWrite: true)
            let token = try XCTUnwrap(secrets.values[grant.id])
            XCTAssertEqual(grant.name, "Test client")
            XCTAssertNotNil(UUID(uuidString: grant.id))
            XCTAssertEqual(grant.allowedListIDs, ["work"])
            XCTAssertTrue(grant.canWrite)
            XCTAssertEqual(token.utf8.count, 43)
            let decoded = Data(base64Encoded: token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=")
            XCTAssertEqual(decoded?.count, 32)
            let metadata = try XCTUnwrap(defaults.data(forKey: AutomationAccessStore.grantsKey))
            XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains(token))
            XCTAssertNil(store.authenticate(clientID: grant.id, token: token))
            XCTAssertEqual(secrets.reads, 0)
            store.enabled = true
            XCTAssertEqual(store.authenticate(clientID: grant.id, token: token), grant)
            let restored = AutomationAccessStore(defaults: defaults, secretStore: secrets)
            XCTAssertTrue(restored.enabled)
            XCTAssertEqual(restored.grants, [grant])
            XCTAssertEqual(restored.authenticate(clientID: grant.id, token: token), grant)
        }
    }

    func testAuthenticationRejectsUnknownDisabledMissingAndIncorrectSecrets() throws {
        try fixture { store, secrets, _ in
            let grant = try store.createGrant(name: "Test", listIDs: ["work"], canWrite: false)
            let token = try XCTUnwrap(secrets.values[grant.id])
            store.enabled = true
            XCTAssertNil(store.authenticate(clientID: UUID().uuidString, token: token))
            XCTAssertEqual(secrets.reads, 0)
            for position in [0, 21, 42] {
                var bytes = Array(token.utf8)
                bytes[position] = bytes[position] == 65 ? 66 : 65
                XCTAssertNil(store.authenticate(clientID: grant.id, token: String(decoding: bytes, as: UTF8.self)))
            }
            for invalid in ["", token + "A", " " + token, String(repeating: "é", count: 43)] {
                XCTAssertNil(store.authenticate(clientID: grant.id, token: invalid))
            }
            store.enabled = false
            let reads = secrets.reads
            XCTAssertNil(store.authenticate(clientID: grant.id, token: token))
            XCTAssertEqual(secrets.reads, reads)
            store.enabled = true
            secrets.failRead = true
            XCTAssertNil(store.authenticate(clientID: grant.id, token: token))
            secrets.failRead = false; secrets.values[grant.id] = nil
            XCTAssertNil(store.authenticate(clientID: grant.id, token: token))
        }
    }

    func testInvalidInputsAndGrantCapDoNotWriteExtraSecrets() throws {
        try fixture { store, secrets, _ in
            for name in ["", " \n ", "A\nB", String(repeating: "a", count: 81)] {
                XCTAssertThrowsError(try store.createGrant(name: name, listIDs: ["work"], canWrite: true))
            }
            for ids: Set<String> in [[], [""], ["  "], ["work\nother"]] {
                XCTAssertThrowsError(try store.createGrant(name: "Test", listIDs: ids, canWrite: true))
            }
            XCTAssertTrue(secrets.values.isEmpty)
            for index in 0..<AutomationAccessStore.maximumGrants {
                _ = try store.createGrant(name: "Client \(index)", listIDs: ["work"], canWrite: false)
            }
            XCTAssertThrowsError(try store.createGrant(name: "One more", listIDs: ["work"], canWrite: false))
            XCTAssertEqual(store.grants.count, AutomationAccessStore.maximumGrants)
            XCTAssertEqual(Set(secrets.values.values).count, AutomationAccessStore.maximumGrants)
        }
    }

    func testSecretWriteFailureDoesNotPublishOrPersistAGrant() throws {
        try fixture { store, secrets, defaults in
            secrets.failWrite = true
            XCTAssertThrowsError(try store.createGrant(name: "Test", listIDs: ["work"], canWrite: true))
            XCTAssertTrue(store.grants.isEmpty)
            XCTAssertNil(defaults.object(forKey: AutomationAccessStore.grantsKey))
        }
    }

    func testRevocationRemainsEffectiveWhenKeychainDeletionFails() throws {
        try fixture { store, secrets, defaults in
            let grant = try store.createGrant(name: "Test", listIDs: ["work"], canWrite: true)
            let token = try XCTUnwrap(secrets.values[grant.id])
            store.enabled = true; secrets.failRemove = true
            XCTAssertThrowsError(try store.revoke(grant.id))
            XCTAssertTrue(store.grants.isEmpty)
            let reads = secrets.reads
            XCTAssertNil(store.authenticate(clientID: grant.id, token: token))
            XCTAssertEqual(secrets.reads, reads)
            let restored = AutomationAccessStore(defaults: defaults, secretStore: secrets)
            XCTAssertTrue(restored.grants.isEmpty)
            XCTAssertNil(restored.authenticate(clientID: grant.id, token: token))
            XCTAssertNoThrow(try restored.revoke(grant.id))
        }
    }

    func testCorruptVersionAndMalformedMetadataFailClosedWithoutReadingSecrets() throws {
        try fixture { _, secrets, defaults in
            let badPayloads: [Any] = [
                "not data",
                Data("not json".utf8),
                try JSONSerialization.data(withJSONObject: ["version": 2, "grants": []]),
                try JSONSerialization.data(withJSONObject: ["version": 1, "grants": [["id": "bad"]]])
            ]
            for value in badPayloads {
                defaults.set(true, forKey: AutomationAccessStore.enabledKey)
                defaults.set(value, forKey: AutomationAccessStore.grantsKey)
                let restored = AutomationAccessStore(defaults: defaults, secretStore: secrets)
                XCTAssertFalse(restored.enabled)
                XCTAssertTrue(restored.grants.isEmpty)
                XCTAssertFalse(defaults.bool(forKey: AutomationAccessStore.enabledKey))
            }
            XCTAssertEqual(secrets.reads, 0)
        }
    }

    func testDuplicateGrantMetadataFailsClosed() throws {
        try fixture { store, secrets, defaults in
            _ = try store.createGrant(name: "Test", listIDs: ["work"], canWrite: false)
            let data = try XCTUnwrap(defaults.data(forKey: AutomationAccessStore.grantsKey))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let grants = try XCTUnwrap(object["grants"] as? [[String: Any]])
            object["grants"] = grants + grants
            defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: AutomationAccessStore.grantsKey)
            defaults.set(true, forKey: AutomationAccessStore.enabledKey)
            let restored = AutomationAccessStore(defaults: defaults, secretStore: secrets)
            XCTAssertFalse(restored.enabled)
            XCTAssertTrue(restored.grants.isEmpty)
        }
    }

    func testExportIsPrivateAndContainsOnlyTheConnectionFields() throws {
        try fixture { store, secrets, _ in
            let grant = try store.createGrant(name: "Test", listIDs: ["work"], canWrite: true)
            try withDirectory { directory in
                let url = directory.appendingPathComponent("connection.json")
                try Data("old data".utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
                try store.exportConnection(grant.id, to: url)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                XCTAssertEqual(Set(object.keys), ["version", "endpoint", "clientID", "token"])
                XCTAssertEqual(object["version"] as? Int, 1)
                XCTAssertEqual(object["endpoint"] as? String, "http://127.0.0.1:49371")
                XCTAssertEqual(object["clientID"] as? String, grant.id)
                XCTAssertEqual(object["token"] as? String, secrets.values[grant.id])
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["connection.json"])
            }
        }
    }

    func testExportRejectsFinalAndParentSymlinksWithoutChangingTargets() throws {
        try fixture { store, _, _ in
            let grant = try store.createGrant(name: "Test", listIDs: ["work"], canWrite: true)
            try withDirectory { directory in
                let sentinel = directory.appendingPathComponent("sentinel")
                try Data("keep".utf8).write(to: sentinel)
                let link = directory.appendingPathComponent("link.json")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sentinel)
                XCTAssertThrowsError(try store.exportConnection(grant.id, to: link))
                XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), sentinel.path)
                let parent = directory.appendingPathComponent("linked-parent")
                try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: directory)
                XCTAssertThrowsError(try store.exportConnection(grant.id, to: parent.appendingPathComponent("new.json")))
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("new.json").path))
                XCTAssertThrowsError(try store.exportConnection(grant.id, to: directory))
            }
        }
    }

    func testExportAtomicallyReplacesExistingFileWithoutChangingItsOtherLinks() throws {
        try fixture { store, _, _ in
            let grant = try store.createGrant(name: "Test", listIDs: ["work"], canWrite: true)
            try withDirectory { directory in
                let output = directory.appendingPathComponent("connection.json")
                let originalLink = directory.appendingPathComponent("original-data.json")
                try Data("preserve original contents".utf8).write(to: output)
                try FileManager.default.linkItem(at: output, to: originalLink)
                let oldAttributes = try FileManager.default.attributesOfItem(atPath: output.path)
                try store.exportConnection(grant.id, to: output)
                let newAttributes = try FileManager.default.attributesOfItem(atPath: output.path)
                XCTAssertNotEqual(oldAttributes[.systemFileNumber] as? NSNumber,
                                  newAttributes[.systemFileNumber] as? NSNumber)
                XCTAssertEqual(try String(contentsOf: originalLink, encoding: .utf8), "preserve original contents")
                XCTAssertEqual((newAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
                XCTAssertEqual(object["clientID"] as? String, grant.id)
            }
        }
    }

    func testExportNeedsSearchAndWriteButNotDirectoryListingPermission() throws {
        try fixture { store, _, _ in
            let grant = try store.createGrant(name: "Test", listIDs: ["work"], canWrite: true)
            try withDirectory { directory in
                let parent = directory.appendingPathComponent("search-and-write-only", isDirectory: true)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: parent.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
                let output = parent.appendingPathComponent("connection.json")
                try store.exportConnection(grant.id, to: output)
                let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
                XCTAssertEqual(object["clientID"] as? String, grant.id)
            }
        }
    }

    func testRevokedOrMissingSecretCannotExportOrAlterExistingFile() throws {
        try fixture { store, secrets, _ in
            let grant = try store.createGrant(name: "Test", listIDs: ["work"], canWrite: true)
            try withDirectory { directory in
                let url = directory.appendingPathComponent("connection.json")
                try Data("keep".utf8).write(to: url)
                secrets.failRead = true
                XCTAssertThrowsError(try store.exportConnection(grant.id, to: url))
                secrets.failRead = false
                try store.revoke(grant.id)
                XCTAssertThrowsError(try store.exportConnection(grant.id, to: url))
                XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "keep")
            }
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        // Foundation preserves macOS's /var alias; use the actual parent so the
        // exporter can enforce its no-parent-symlink rule during these tests.
        let resolved = try XCTUnwrap(Darwin.realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(resolved) }
        let directory = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("HeyNotchAutomationAccessTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private final class FakeAutomationSecrets: AutomationSecretStore {
    var values: [String: String] = [:]
    var reads = 0
    var failRead = false
    var failWrite = false
    var failRemove = false
    func read(_ id: String) throws -> String? {
        reads += 1
        if failRead { throw AutomationAccessError.unavailableSecret }
        return values[id]
    }
    func write(_ token: String, for id: String) throws {
        if failWrite { throw AutomationAccessError.unavailableSecret }
        values[id] = token
    }
    func remove(_ id: String) throws {
        if failRemove { throw AutomationAccessError.unavailableSecret }
        values[id] = nil
    }
}
