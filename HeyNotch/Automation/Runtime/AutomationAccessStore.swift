import Combine
import Darwin
import Foundation
import LocalAuthentication
import Security

struct AutomationGrant: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let allowedListIDs: Set<String>
    let canWrite: Bool
    let createdAt: Date
}

protocol AutomationSecretStore {
    func read(_ id: String) throws -> String?
    func write(_ token: String, for id: String) throws
    func remove(_ id: String) throws
}

enum AutomationAccessError: Error, LocalizedError, Equatable {
    case invalidName, invalidLists, grantLimit, missingGrant, unavailableSecret
    case randomFailure, keychain(OSStatus), unsafeDestination, exportFailed

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Enter a client name between 1 and 80 characters."
        case .invalidLists: return "Choose at least one valid Reminders list."
        case .grantLimit: return "Revoke an existing client before adding another. Up to 32 clients are supported."
        case .missingGrant: return "This client no longer has access."
        case .unavailableSecret: return "The connection secret is unavailable. Revoke this client and create a new connection."
        case .randomFailure: return "A secure connection secret could not be generated."
        case .keychain: return "The connection secret could not be accessed in Keychain."
        case .unsafeDestination: return "Choose a regular file in a folder without symbolic links."
        case .exportFailed: return "The connection file could not be saved."
        }
    }
}

/// The account is the grant UUID; no secret is written to preferences or logs.
final class KeychainAutomationSecretStore: AutomationSecretStore {
    private let service = "com.wolfieeee.heynotch.automation"

    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id,
         kSecAttrSynchronizable as String: false]
    }

    func read(_ id: String) throws -> String? {
        var value = query(id)
        value[kSecReturnData as String] = true
        value[kSecMatchLimit as String] = kSecMatchLimitOne
        // Requests must fail closed, rather than make background authentication prompt.
        let context = LAContext()
        context.interactionNotAllowed = true
        value[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(value as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AutomationAccessError.keychain(status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw AutomationAccessError.unavailableSecret
        }
        return token
    }

    func write(_ token: String, for id: String) throws {
        var value = query(id)
        value[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        value[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(value as CFDictionary, nil)
        guard status == errSecSuccess else { throw AutomationAccessError.keychain(status) }
    }

    func remove(_ id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AutomationAccessError.keychain(status)
        }
    }
}

@MainActor
final class AutomationAccessStore: ObservableObject {
    static let shared = AutomationAccessStore()
    static let enabledKey = "automation.enabled.v1"
    static let grantsKey = "automation.grants.v1"
    static let maximumGrants = 32
    static let endpoint = "http://127.0.0.1:49371"

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.enabledKey) }
    }
    @Published private(set) var grants: [AutomationGrant]

    private let defaults: UserDefaults
    private let secretStore: any AutomationSecretStore
    private struct Metadata: Codable { let version: Int; let grants: [AutomationGrant] }
    private struct Connection: Codable {
        let version: Int
        let endpoint: String
        let clientID: String
        let token: String
    }

    init(defaults: UserDefaults = .standard, secretStore: any AutomationSecretStore = KeychainAutomationSecretStore()) {
        self.defaults = defaults
        self.secretStore = secretStore
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
        grants = []
        guard defaults.object(forKey: Self.grantsKey) != nil else { return }
        guard let data = defaults.data(forKey: Self.grantsKey), data.count <= 1_048_576,
              let stored = try? JSONDecoder().decode(Metadata.self, from: data),
              stored.version == 1, stored.grants.count <= Self.maximumGrants,
              Set(stored.grants.map(\.id)).count == stored.grants.count,
              stored.grants.allSatisfy(Self.validGrant) else {
            enabled = false
            defaults.set(false, forKey: Self.enabledKey)
            return
        }
        grants = stored.grants
    }

    func createGrant(name: String, listIDs: Set<String>, canWrite: Bool) throws -> AutomationGrant {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validName(name) else { throw AutomationAccessError.invalidName }
        guard Self.validLists(listIDs) else { throw AutomationAccessError.invalidLists }
        guard grants.count < Self.maximumGrants else { throw AutomationAccessError.grantLimit }
        let grant = AutomationGrant(id: UUID().uuidString, name: name, allowedListIDs: listIDs,
                                    canWrite: canWrite, createdAt: Date())
        let updated = grants + [grant]
        let metadata = try JSONEncoder().encode(Metadata(version: 1, grants: updated))
        guard metadata.count <= 1_048_576 else { throw AutomationAccessError.grantLimit }
        let token = try Self.randomToken()
        try secretStore.write(token, for: grant.id)
        defaults.set(metadata, forKey: Self.grantsKey)
        grants = updated
        return grant
    }

    func revoke(_ id: String) throws {
        guard grants.contains(where: { $0.id == id }) else { return }
        let updated = grants.filter { $0.id != id }
        let metadata = try JSONEncoder().encode(Metadata(version: 1, grants: updated))
        // Remove authorization before Keychain deletion, including if deletion fails.
        defaults.set(metadata, forKey: Self.grantsKey)
        grants = updated
        try secretStore.remove(id)
    }

    func authenticate(clientID: String, token: String) -> AutomationGrant? {
        guard enabled, Self.validToken(token),
              let grant = grants.first(where: { $0.id == clientID }),
              let stored = try? secretStore.read(clientID), Self.validToken(stored),
              Self.constantTimeEqual(stored, token) else { return nil }
        return grant
    }

    func exportConnection(_ id: String, to URL: URL) throws {
        guard grants.contains(where: { $0.id == id }) else { throw AutomationAccessError.missingGrant }
        guard let token = try secretStore.read(id), Self.validToken(token) else {
            throw AutomationAccessError.unavailableSecret
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Connection(version: 1, endpoint: Self.endpoint, clientID: id, token: token))
        try Self.writePrivateFile(data, to: URL)
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 80 && name.utf8.count <= 320
            && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private static func validLists(_ listIDs: Set<String>) -> Bool {
        !listIDs.isEmpty && listIDs.count <= 256 && listIDs.allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 1_024
                && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
    }
    private static func validGrant(_ grant: AutomationGrant) -> Bool {
        UUID(uuidString: grant.id)?.uuidString == grant.id && validName(grant.name)
            && validLists(grant.allowedListIDs) && grant.createdAt.timeIntervalSince1970.isFinite
    }
    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw AutomationAccessError.randomFailure }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func validToken(_ token: String) -> Bool {
        token.utf8.count == 43 && token.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
    private static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        // Both lengths are public and validated as exactly 43 before comparing.
        let left = Array(left.utf8), right = Array(right.utf8)
        guard left.count == 43, right.count == 43 else { return false }
        var difference: UInt8 = 0
        for index in 0..<43 { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    private static func writePrivateFile(_ data: Data, to url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.hasDirectoryPath else {
            throw AutomationAccessError.unsafeDestination
        }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let filename = parts.last, parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw AutomationAccessError.unsafeDestination
        }
        var directory = Darwin.open("/", O_SEARCH | O_CLOEXEC)
        guard directory >= 0 else { throw AutomationAccessError.exportFailed }
        defer { Darwin.close(directory) }
        // A save-panel grant need not allow listing parent directories. Search-only
        // descriptors preserve the no-symlink walk without requesting directory reads.
        // Relative writes and rename stay anchored to the opened destination directory.
        for part in parts.dropLast() {
            let next = Darwin.openat(directory, part, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw AutomationAccessError.unsafeDestination }
            Darwin.close(directory); directory = next
        }
        var existing = stat()
        if Darwin.fstatat(directory, filename, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG else { throw AutomationAccessError.unsafeDestination }
        } else if errno != ENOENT { throw AutomationAccessError.exportFailed }

        // NSSavePanel authorizes the chosen file, not new siblings beside it.
        // Foundation supplies a writable replacement directory on the same volume,
        // so the private staged file can still be committed with one atomic rename.
        let stagingURL: URL
        do {
            stagingURL = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                     appropriateFor: url, create: true)
        } catch { throw AutomationAccessError.exportFailed }
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        let staging = Darwin.open(stagingURL.path, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard staging >= 0 else { throw AutomationAccessError.exportFailed }
        defer { Darwin.close(staging) }
        var destinationInfo = stat(), stagingInfo = stat()
        guard Darwin.fstat(directory, &destinationInfo) == 0,
              Darwin.fstat(staging, &stagingInfo) == 0,
              stagingInfo.st_mode & S_IFMT == S_IFDIR,
              stagingInfo.st_uid == geteuid(),
              stagingInfo.st_dev == destinationInfo.st_dev else {
            throw AutomationAccessError.exportFailed
        }

        let temporary = ".heynotch-connection-" + UUID().uuidString
        let file = Darwin.openat(staging, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw AutomationAccessError.exportFailed }
        defer { Darwin.close(file); Darwin.unlinkat(staging, temporary, 0) }
        guard Darwin.fchmod(file, mode_t(0o600)) == 0 else { throw AutomationAccessError.exportFailed }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw AutomationAccessError.exportFailed }
                offset += written
            }
        }
        guard Darwin.fsync(file) == 0,
              Darwin.renameat(staging, temporary, directory, filename) == 0 else {
            throw AutomationAccessError.exportFailed
        }
    }
}
