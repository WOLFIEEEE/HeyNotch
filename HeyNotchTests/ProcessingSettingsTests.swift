import Foundation
import XCTest

@MainActor
final class ProcessingSettingsTests: XCTestCase {
    private func withStore(_ test: (ProcessingSettingsStore, UserDefaults) async throws -> Void) async rethrows {
        let suite = "HeyNotchTests.processing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try await test(ProcessingSettingsStore(defaults: defaults), defaults)
    }

    func testProviderSelectionsSurviveSwitchingAndRelaunch() async {
        await withStore { store, defaults in
            XCTAssertFalse(store.preferences.enabled)
            store.configure(.anthropic) { $0.modelID = "claude-exact" }
            store.update { $0.activeProvider = .openrouter }
            store.configure(.openrouter) { $0.modelID = "publisher/model" }
            store.update { $0.activeProvider = .anthropic }
            let reopened = ProcessingSettingsStore(defaults: defaults)
            XCTAssertEqual(reopened.preferences.configuration(.anthropic).modelID, "claude-exact")
            XCTAssertEqual(reopened.preferences.configuration(.openrouter).modelID, "publisher/model")
            XCTAssertFalse(reopened.preferences.enabled)
        }
    }

    func testKeyRotationInvalidatesCatalogAndTestButPreservesSelection() async {
        await withStore { store, _ in
            store.configure(.openai) { $0.modelID = "exact-model" }
            let config = store.preferences.configuration(.openai)
            let snapshot = ProcessingSnapshot(provider: .openai, configuration: config, model: .manual(config.modelID), key: "fixture", timeout: 15, preferencesRevision: store.preferences.revision)
            store.recordModels([.manual(config.modelID)], snapshot: snapshot)
            store.recordTest(ModelTestResult(revision: config.revision, modelID: config.modelID, testedAt: Date(), elapsedMilliseconds: 20, structuredOutput: true), provider: .openai)
            store.credentialsChanged(.openai)
            XCTAssertNil(store.catalog(.openai))
            XCTAssertNil(store.preferences.configuration(.openai).test)
            XCTAssertEqual(store.preferences.configuration(.openai).modelID, "exact-model")
            store.recordModels([.manual("late-old-response")], snapshot: snapshot)
            XCTAssertNil(store.catalog(.openai))
        }
    }

    func testSavedKeysNeverEnterPreferences() async {
        await withStore { store, defaults in
            let keys = FixtureKeyStore()
            let controller = ProcessingController(store: store, keys: keys)
            let saved = await controller.saveKey("private-provider-secret", provider: .openai)
            XCTAssertTrue(saved)
            let value = defaults.dictionaryRepresentation().description
            XCTAssertFalse(value.contains("private-provider-secret"))
            let json = defaults.data(forKey: "processing.preferences.v1")!
            XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("private-provider-secret"))
            XCTAssertFalse(store.preferences.enabled)
        }
    }

    func testFailedKeyReplacementKeepsOldConfigurationAndKey() async throws {
        try await withStore { store, _ in
            let keys = FixtureKeyStore()
            try await keys.save("old-key", for: .anthropic)
            await keys.setFailure(true)
            let controller = ProcessingController(store: store, keys: keys)
            let revision = store.preferences.configuration(.anthropic).revision
            let saved = await controller.saveKey("replacement", provider: .anthropic)
            XCTAssertFalse(saved)
            XCTAssertEqual(store.preferences.configuration(.anthropic).revision, revision)
            let key = try await keys.read(.anthropic)
            XCTAssertEqual(key, "old-key")
        }
    }

    func testNewModelSelectionInvalidatesPreviousTestWithoutChangingCatalog() async {
        await withStore { store, _ in
            store.configure(.openrouter) { $0.modelID = "publisher/one" }
            let config = store.preferences.configuration(.openrouter)
            let snapshot = ProcessingSnapshot(provider: .openrouter, configuration: config, model: .manual(config.modelID), key: "fixture", timeout: 15, preferencesRevision: store.preferences.revision)
            store.recordModels([.manual("publisher/one"), .manual("publisher/two")], snapshot: snapshot)
            store.recordTest(ModelTestResult(revision: config.revision, modelID: config.modelID, testedAt: Date(), elapsedMilliseconds: 1, structuredOutput: true), provider: .openrouter)
            store.configure(.openrouter) { $0.modelID = "publisher/two" }
            XCTAssertNil(store.preferences.configuration(.openrouter).test)
            XCTAssertEqual(store.catalog(.openrouter)?.models.count, 2)
        }
    }
}

actor FixtureKeyStore: ProviderKeyStoring {
    private var keys: [ProcessingProvider: String] = [:]
    private var fail = false
    func setFailure(_ fail: Bool) { self.fail = fail }
    func read(_ provider: ProcessingProvider) throws -> String? { keys[provider] }
    func save(_ key: String, for provider: ProcessingProvider) throws {
        if fail { throw ProcessingError.keychain(-1) }
        keys[provider] = key
    }
    func remove(_ provider: ProcessingProvider) throws { keys[provider] = nil }
}
