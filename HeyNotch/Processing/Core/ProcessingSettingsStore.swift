import Combine
import Foundation

@MainActor
final class ProcessingSettingsStore: ObservableObject {
    static let shared = ProcessingSettingsStore()
    @Published private(set) var preferences: ProcessingPreferences
    private let defaults: UserDefaults
    private let storageKey = "processing.preferences.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var value = defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(ProcessingPreferences.self, from: $0) } ?? ProcessingPreferences()
        for provider in ProcessingProvider.allCases where value.providers[provider.rawValue] == nil {
            value.providers[provider.rawValue] = ProviderConfiguration()
        }
        preferences = value
    }

    func update(_ edit: (inout ProcessingPreferences) -> Void) {
        var value = preferences
        edit(&value)
        value.revision = UUID()
        value.timeout = min(60, max(5, value.timeout))
        commit(value)
        NotificationCenter.default.post(name: .processingConfigurationChanged, object: nil)
    }

    func configure(_ provider: ProcessingProvider, _ edit: (inout ProviderConfiguration) -> Void) {
        update { value in
            var configuration = value.configuration(provider)
            edit(&configuration)
            configuration.revision = UUID()
            configuration.test = nil
            configuration.outputTokenLimit = min(16_384, max(256, configuration.outputTokenLimit))
            value.providers[provider.rawValue] = configuration
        }
    }

    func credentialsChanged(_ provider: ProcessingProvider) {
        update { value in
            var configuration = value.configuration(provider)
            configuration.revision = UUID()
            configuration.credentialRevision = UUID()
            configuration.verifiedAt = nil
            configuration.test = nil
            value.providers[provider.rawValue] = configuration
            value.catalogs.removeValue(forKey: provider.rawValue)
        }
    }

    func setAccountContext(_ context: String, provider: ProcessingProvider) {
        let clean = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.contains(where: { $0.isNewline || $0 == "\r" }), clean.utf8.count <= 256 else { return }
        configure(provider) { $0.accountContext = clean }
        credentialsChanged(provider)
    }

    func recordModels(_ models: [ProcessingModel], snapshot: ProcessingSnapshot) {
        guard configurationMatches(snapshot) else { return }
        var value = preferences
        value.catalogs[snapshot.provider.rawValue] = ModelCatalog(credentialRevision: snapshot.configuration.credentialRevision,
                                                                 fetchedAt: Date(), models: models)
        value.providers[snapshot.provider.rawValue]?.verifiedAt = Date()
        commit(value)
    }

    func recordTest(_ test: ModelTestResult, provider: ProcessingProvider) {
        guard preferences.configuration(provider).revision == test.revision else { return }
        var value = preferences
        value.providers[provider.rawValue]?.test = test
        commit(value)
    }

    func configurationMatches(_ snapshot: ProcessingSnapshot) -> Bool {
        preferences.configuration(snapshot.provider).revision == snapshot.configuration.revision
    }

    func selection(_ provider: ProcessingProvider) -> ProcessingModel {
        let config = preferences.configuration(provider)
        return catalog(provider)?.models.first { $0.id == config.modelID }
            ?? ProviderAPI.parseModel(["id": config.modelID], provider: provider) ?? .manual(config.modelID)
    }

    func catalog(_ provider: ProcessingProvider) -> ModelCatalog? {
        guard let catalog = preferences.catalogs[provider.rawValue],
              catalog.credentialRevision == preferences.configuration(provider).credentialRevision else { return nil }
        return catalog
    }

    private func commit(_ value: ProcessingPreferences) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: storageKey) }
        preferences = value
    }
}

extension Notification.Name {
    static let processingConfigurationChanged = Notification.Name("processingConfigurationChanged")
}
