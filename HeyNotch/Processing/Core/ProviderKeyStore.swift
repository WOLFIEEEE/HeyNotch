import Foundation
import Security

protocol ProviderKeyStoring: Sendable {
    func read(_ provider: ProcessingProvider) async throws -> String?
    func save(_ key: String, for provider: ProcessingProvider) async throws
    func remove(_ provider: ProcessingProvider) async throws
}

actor ProviderKeyStore: ProviderKeyStoring {
    private let service: String
    init(service: String = "com.wolfieeee.heynotch.processing") { self.service = service }

    private func query(_ provider: ProcessingProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: provider.rawValue,
         kSecAttrSynchronizable as String: false]
    }

    func read(_ provider: ProcessingProvider) throws -> String? {
        var query = query(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw ProcessingError.keychain(status) }
        return key
    }

    func save(_ key: String, for provider: ProcessingProvider) throws {
        guard !key.isEmpty, key.utf8.count <= 8192, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw ProcessingError.invalidKeyFormat
        }
        let query = query(provider)
        let changes = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(changes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrLabel as String] = "HeyNotch \(provider.name) API key"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ProcessingError.keychain(status) }
    }

    func remove(_ provider: ProcessingProvider) throws {
        let status = SecItemDelete(query(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ProcessingError.keychain(status) }
    }
}
