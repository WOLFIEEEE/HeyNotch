import Combine
import Foundation

@MainActor
final class ProcessingController: ObservableObject {
    static let shared = ProcessingController(store: .shared)
    let store: ProcessingSettingsStore
    let keys: any ProviderKeyStoring
    let api: ProviderAPI
    @Published private(set) var hasKey: [ProcessingProvider: Bool] = [:]
    @Published private(set) var messages: [ProcessingProvider: String] = [:]
    @Published private(set) var isWorking = false
    private var task: Task<Void, Never>?
    private var job = UUID()
    private var activeWork: (provider: ProcessingProvider, message: String, cancelledMessage: String)?

    init(store: ProcessingSettingsStore, keys: any ProviderKeyStoring = ProviderKeyStore(), api: ProviderAPI = ProviderAPI()) {
        self.store = store; self.keys = keys; self.api = api
    }

    func cancel() {
        job = UUID()
        task?.cancel()
        task = nil
        if let activeWork, messages[activeWork.provider] == activeWork.message {
            messages[activeWork.provider] = activeWork.cancelledMessage
        }
        activeWork = nil
        isWorking = false
    }

    func preparePane(for provider: ProcessingProvider) async {
        let paneJob = job
        do {
            try Task.checkCancellation()
            let exists = try await keys.read(provider) != nil
            // Keychain reads can finish after SwiftUI cancels its pane task.
            // They must not restart work or overwrite a newer pane's state.
            guard !Task.isCancelled, job == paneJob,
                  store.preferences.activeProvider == provider else { return }
            hasKey[provider] = exists
            if exists && !(store.catalog(provider)?.isFresh(at: Date()) ?? false) { refresh(provider) }
        } catch {
            guard !Task.isCancelled, job == paneJob,
                  store.preferences.activeProvider == provider else { return }
            messages[provider] = ProcessingError.sanitized(error)
        }
    }

    func saveKey(_ key: String, provider: ProcessingProvider) async -> Bool {
        cancel()
        do {
            try await keys.save(key.trimmingCharacters(in: .whitespacesAndNewlines), for: provider)
            store.credentialsChanged(provider)
            hasKey[provider] = true
            messages[provider] = "Key saved in Keychain. Verification has not run."
            return true
        } catch { messages[provider] = ProcessingError.sanitized(error); return false }
    }

    func removeKey(_ provider: ProcessingProvider) async {
        cancel()
        do {
            try await keys.remove(provider)
            store.credentialsChanged(provider)
            hasKey[provider] = false
            messages[provider] = "Key removed from HeyNotch. To revoke it, use the provider’s account settings."
        } catch { messages[provider] = ProcessingError.sanitized(error) }
    }

    func revealKey(_ provider: ProcessingProvider) async -> String? {
        do { return try await keys.read(provider) }
        catch { messages[provider] = ProcessingError.sanitized(error); return nil }
    }

    func snapshot(_ provider: ProcessingProvider? = nil) async throws -> ProcessingSnapshot {
        let value = store.preferences
        let provider = provider ?? value.activeProvider
        let config = value.configuration(provider)
        let key = try await keys.read(provider)
        try Task.checkCancellation()
        guard let key, !key.isEmpty else { throw ProcessingError.missingKey }
        guard store.preferences.configuration(provider).revision == config.revision else { throw ProcessingError.configurationChanged }
        return ProcessingSnapshot(provider: provider, configuration: config, model: store.selection(provider),
                                   key: key, timeout: value.timeout, preferencesRevision: value.revision)
    }

    func refresh(_ provider: ProcessingProvider) {
        launch(provider, message: "Verifying key and loading models…", cancelledMessage: "Verification cancelled.") { [self] id in
            let snapshot = try await snapshot(provider)
            if provider == .openrouter { try await api.verifyOpenRouterKey(snapshot) }
            let models = try await api.models(snapshot)
            guard job == id else { return }
            guard store.configurationMatches(snapshot) else { throw ProcessingError.configurationChanged }
            store.recordModels(models, snapshot: snapshot)
            hasKey[provider] = true
            messages[provider] = "Key verified. \(models.count) models loaded. Model access still needs a generation test."
        }
    }

    func testModel(_ provider: ProcessingProvider, structured: Bool = false) {
        launch(provider, message: structured ? "Testing structured output…" : "Testing selected model…",
               cancelledMessage: "Model test cancelled.") { [self] id in
            let snapshot = try await snapshot(provider)
            let started = Date()
            let output = try await api.generate(snapshot,
                instruction: structured ? "Return a JSON object with the field text set to Hello from HeyNotch." : "Return exactly: Hello from HeyNotch.",
                input: "This is a short connection test using synthetic text.", schema: structured ? .probe : nil, tokenLimit: 2048)
            if structured {
                guard let data = output.text.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["text"] as? String == "Hello from HeyNotch" else { throw ProcessingError.invalidOutput }
            }
            guard job == id else { return }
            guard store.configurationMatches(snapshot) else { throw ProcessingError.configurationChanged }
            let previous = store.preferences.configuration(provider).test
            let result = ModelTestResult(revision: snapshot.configuration.revision, modelID: snapshot.configuration.modelID,
                                          testedAt: Date(), elapsedMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
                                          structuredOutput: structured || previous?.structuredOutput == true)
            store.recordTest(result, provider: provider)
            messages[provider] = "Model tested successfully in \(result.elapsedMilliseconds) ms\(structured ? ", including structured output" : "")."
        }
    }

    private func launch(_ provider: ProcessingProvider, message: String, cancelledMessage: String,
                        work: @escaping @MainActor (UUID) async throws -> Void) {
        cancel()
        let id = job
        isWorking = true
        messages[provider] = message
        activeWork = (provider, message, cancelledMessage)
        task = Task { [weak self] in
            do { try await work(id) }
            catch { if self?.job == id { self?.messages[provider] = ProcessingError.sanitized(error) } }
            if self?.job == id { self?.isWorking = false; self?.task = nil; self?.activeWork = nil }
        }
    }
}
