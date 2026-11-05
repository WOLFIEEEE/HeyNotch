import SwiftUI

@MainActor
struct ProcessingSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var store = ProcessingSettingsStore.shared
    @ObservedObject private var controller = ProcessingController.shared
    @State private var keyInput = ""
    @State private var reveal = false
    @State private var revealedKey = ""
    @State private var search = ""
    @State private var manualID = ""
    @State private var accountContext = ""
    @State private var savingKey = false
    @FocusState private var keyFocused: Bool

    private var provider: ProcessingProvider { store.preferences.activeProvider }
    private var configuration: ProviderConfiguration { store.preferences.configuration(provider) }
    private var model: ProcessingModel { store.selection(provider) }
    private var catalog: ModelCatalog? { store.catalog(provider) }

    private func providerAssetName(_ candidate: ProcessingProvider) -> String {
        switch candidate {
        case .anthropic: "ProviderClaude"
        case .openai: "ProviderOpenAI"
        case .openrouter: "ProviderOpenRouter"
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("AI processing", isOn: preference(\.enabled))
                Text("Optional processing sends the transcript directly to your chosen provider. Speech recognition stays on your Mac. Your provider bills API usage to your account.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Provider", selection: preference(\.activeProvider)) {
                    ForEach(ProcessingProvider.allCases) { candidate in
                        Label {
                            Text(candidate.name)
                        } icon: {
                            Image(providerAssetName(candidate))
                                .renderingMode(candidate == .openai ? .template : .original)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 18, height: 18)
                                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                                .accessibilityHidden(true)
                        }
                        .tag(candidate)
                    }
                }
                if !configuration.modelID.isEmpty {
                    LabeledContent("Selected model", value: configuration.modelID)
                        .textSelection(.enabled)
                }
                if provider == .openrouter {
                    Text("OpenRouter routes requests to hosts for your chosen model under your account’s privacy and routing settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("API key") {
                LabeledContent("Storage", value: controller.hasKey[provider] == true ? "Saved in macOS Keychain" : "No saved key")
                if let date = configuration.verifiedAt { LabeledContent("Key verified", value: date.formatted(date: .abbreviated, time: .shortened)) }
                Group {
                    SecureField("New or replacement API key", text: $keyInput)
                }
                .focused($keyFocused)
                .autocorrectionDisabled()
                HStack {
                    Button("Save key") {
                        let target = provider
                        let candidate = keyInput
                        savingKey = true
                        Task {
                            if await controller.saveKey(candidate, provider: target), provider == target { keyInput = ""; revealedKey = ""; reveal = false }
                            savingKey = false
                        }
                    }
                    .disabled(keyInput.isEmpty || savingKey)
                    Button(reveal ? "Hide" : "Reveal saved key") {
                        if reveal { reveal = false; revealedKey = "" }
                        else {
                            let target = provider
                            Task {
                                if let key = await controller.revealKey(target), provider == target {
                                    revealedKey = key; reveal = true
                                }
                            }
                        }
                    }
                    .disabled(controller.hasKey[provider] != true || savingKey)
                    Button("Remove", role: .destructive) { let target = provider; Task { await controller.removeKey(target); if provider == target { keyInput = ""; revealedKey = ""; reveal = false } } }
                        .disabled(controller.hasKey[provider] != true || savingKey)
                }
                if reveal { Text(revealedKey).font(.caption.monospaced()).textSelection(.enabled) }
                HStack {
                    Button("Verify key") { controller.refresh(provider) }
                        .disabled(controller.hasKey[provider] != true || controller.isWorking)
                    Link("Manage API keys", destination: provider.keyURL)
                }
                if provider != .openrouter {
                    TextField(provider == .anthropic ? "Workspace ID, if required" : "Project ID, optional", text: $accountContext)
                        .autocorrectionDisabled()
                    Button("Save account context") { controller.cancel(); store.setAccountContext(accountContext, provider: provider) }
                        .disabled(accountContext == configuration.accountContext)
                }
            }
            Section("Model") {
                TextField("Search model name or ID", text: $search)
                if let catalog {
                    Text("\(catalog.models.count) models · \(catalog.isFresh(at: Date()) ? "Updated" : "Cached") \(catalog.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(catalog.models.filter { search.isEmpty || "\($0.name) \($0.id) \($0.publisher ?? "")".localizedCaseInsensitiveContains(search) }) { candidate in
                                Button {
                                    controller.cancel()
                                    store.configure(provider) { $0.modelID = candidate.id }
                                } label: {
                                    HStack(alignment: .top) {
                                        Image(systemName: candidate.id == configuration.modelID ? "checkmark.circle.fill" : "circle")
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(candidate.name).font(.callout)
                                            Text(candidate.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                                            Text(!candidate.canSelect ? "Unavailable for text processing" : candidate.lifecycle == "deprecated" ? "Deprecated" : candidate.textSupport == .unknown ? "Compatibility unverified" : "Text generation")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(.vertical, 8).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!candidate.canSelect)
                                .accessibilityLabel("\(candidate.name), \(candidate.id)\(candidate.id == configuration.modelID ? ", selected" : "")")
                                Divider()
                            }
                        }
                    }.frame(height: 210)
                } else {
                    Text("Save a key and verify it to load available models. You can also enter an exact model ID.")
                        .foregroundStyle(.secondary)
                }
                if !configuration.modelID.isEmpty, catalog?.models.contains(where: { $0.id == configuration.modelID }) == false {
                    Text("Your selected ID is not in the current catalogue. It has been kept; test it to check access.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Enter model ID manually", text: $manualID).autocorrectionDisabled()
                    Button("Use ID") {
                        let id = manualID.trimmingCharacters(in: .whitespacesAndNewlines)
                        controller.cancel()
                        store.configure(provider) { $0.modelID = id }
                        manualID = ""
                    }.disabled(manualID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manualID.count > 256)
                }
                HStack {
                    Button("Refresh models") { controller.refresh(provider) }
                    Button("Test model") { controller.testModel(provider) }
                        .disabled(configuration.modelID.isEmpty || !model.canSelect)
                }.disabled(controller.isWorking || controller.hasKey[provider] != true)
                Text("Testing sends a small fixed sample and uses API credits. Catalogue access alone does not verify model generation.")
                    .font(.caption).foregroundStyle(.secondary)
                if let test = configuration.test {
                    Text("Model tested \(test.testedAt.formatted(date: .abbreviated, time: .shortened)) · \(test.elapsedMilliseconds) ms\(test.structuredOutput ? " · Structured output verified" : "")")
                        .font(.caption)
                }
                if let input = model.inputPricePerMillion, let output = model.outputPricePerMillion {
                    Text("Catalogue price per million tokens: $\(input.formatted()) input / $\(output.formatted()) output. Account charges may differ.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Link("Provider pricing", destination: provider.pricingURL)
            }
            Section("Processing behaviour") {
                Picker("Cleanup style", selection: preference(\.cleanupStyle)) {
                    ForEach(CleanupStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Allow AI assistance for task drafts", isOn: preference(\.taskAssistance))
                Picker("When processing fails", selection: preference(\.failurePreference)) {
                    ForEach(ProcessingFailurePreference.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Stepper("Response wait: \(Int(store.preferences.timeout)) seconds", value: preference(\.timeout), in: 5...60, step: 5)
            }
            Section("Model options") {
                Stepper("Output limit: \(configuration.outputTokenLimit) tokens", value: Binding(get: { configuration.outputTokenLimit }, set: { value in store.configure(provider) { $0.outputTokenLimit = value } }), in: 256...16_384, step: 256)
                if model.supportedParameters.contains("temperature") {
                    Slider(value: Binding(get: { configuration.temperature ?? 0.2 }, set: { value in store.configure(provider) { $0.temperature = value } }), in: 0...1) {
                        Text("Temperature")
                    }
                }
                Button("Test structured task support") { controller.testModel(provider, structured: true) }
                    .disabled(controller.isWorking || controller.hasKey[provider] != true || configuration.modelID.isEmpty || model.structuredSupport == .unsupported || !model.canSelect)
                Text("This additional test uses API credits. Unsupported or unverified task output is kept for review.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if controller.isWorking { HStack { ProgressView().controlSize(.small); Button("Cancel") { controller.cancel() } } }
                Text(controller.messages[provider] ?? "Choose a provider to configure processing.")
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Processing")
        .task(id: provider) {
            controller.cancel(); keyInput = ""; revealedKey = ""; reveal = false; search = ""; manualID = ""
            accountContext = configuration.accountContext
            await controller.preparePane(for: provider)
        }
        .onChange(of: keyFocused) { _, focused in if !focused && reveal { reveal = false; revealedKey = "" } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in revealedKey = ""; reveal = false }
        .onDisappear { keyInput = ""; revealedKey = ""; reveal = false; controller.cancel() }
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<ProcessingPreferences, Value>) -> Binding<Value> {
        Binding(get: { store.preferences[keyPath: keyPath] }, set: { value in controller.cancel(); store.update { $0[keyPath: keyPath] = value } })
    }
}
