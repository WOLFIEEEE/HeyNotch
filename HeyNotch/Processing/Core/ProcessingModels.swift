import Foundation

enum ProcessingProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case anthropic, openai, openrouter
    var id: String { rawValue }
    var name: String {
        switch self { case .anthropic: return "Claude (Anthropic)"; case .openai: return "OpenAI"; case .openrouter: return "OpenRouter" }
    }
    var baseURL: String {
        switch self { case .anthropic: return "https://api.anthropic.com/v1"; case .openai: return "https://api.openai.com/v1"; case .openrouter: return "https://openrouter.ai/api/v1" }
    }
    var keyURL: URL {
        URL(string: self == .anthropic ? "https://platform.claude.com/settings/keys" : self == .openai ? "https://platform.openai.com/api-keys" : "https://openrouter.ai/settings/keys")!
    }
    var pricingURL: URL {
        URL(string: self == .anthropic ? "https://platform.claude.com/docs/en/about-claude/pricing" : self == .openai ? "https://openai.com/api/pricing/" : "https://openrouter.ai/models")!
    }
}

enum CapabilitySupport: String, Codable, Sendable { case supported, unsupported, unknown }
enum CleanupStyle: String, Codable, CaseIterable, Sendable { case off = "Off", light = "Light", formal = "Formal" }
enum ProcessingFailurePreference: String, Codable, CaseIterable, Sendable { case review = "Keep for review", useOriginal = "Use original text" }

struct ProcessingModel: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    var publisher: String?
    var textSupport: CapabilitySupport = .unknown
    var structuredSupport: CapabilitySupport = .unknown
    var lifecycle: String?
    var contextLimit: Int?
    var outputLimit: Int?
    var supportedParameters: [String] = []
    var inputPricePerMillion: Double?
    var outputPricePerMillion: Double?
    var canSelect: Bool { textSupport != .unsupported && lifecycle != "retired" }

    static func manual(_ id: String) -> Self { Self(id: id, name: id) }
}

struct ModelTestResult: Codable, Sendable {
    let revision: UUID
    let modelID: String
    let testedAt: Date
    let elapsedMilliseconds: Int
    var structuredOutput: Bool
}

struct ProviderConfiguration: Codable, Sendable {
    var modelID = ""
    var accountContext = ""
    var revision = UUID()
    var credentialRevision = UUID()
    var verifiedAt: Date?
    var test: ModelTestResult?
    var outputTokenLimit = 2048
    var temperature: Double?
}

struct ModelCatalog: Codable, Sendable {
    let credentialRevision: UUID
    let fetchedAt: Date
    let models: [ProcessingModel]
    func isFresh(at date: Date) -> Bool { date.timeIntervalSince(fetchedAt) >= 0 && date.timeIntervalSince(fetchedAt) < 86_400 }
}

struct ProcessingPreferences: Codable, Sendable {
    var enabled = false
    var activeProvider: ProcessingProvider = .anthropic
    var cleanupStyle: CleanupStyle = .light
    var taskAssistance = false
    var failurePreference: ProcessingFailurePreference = .review
    var timeout: TimeInterval = 15
    var revision = UUID()
    var providers: [String: ProviderConfiguration] = [:]
    var catalogs: [String: ModelCatalog] = [:]
    func configuration(_ provider: ProcessingProvider) -> ProviderConfiguration { providers[provider.rawValue] ?? ProviderConfiguration() }
}

struct ProcessingSnapshot: Sendable {
    let provider: ProcessingProvider
    let configuration: ProviderConfiguration
    let model: ProcessingModel
    let key: String
    let timeout: TimeInterval
    let preferencesRevision: UUID
}

struct ProcessingOutput: Sendable {
    let text: String
    let inputTokens: Int?
    let outputTokens: Int?
}

enum ProcessingSchema: Sendable {
    case probe, taskProposal
    var json: [String: Any] {
        switch self {
        case .probe:
            return ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"], "additionalProperties": false]
        case .taskProposal:
            return ["type": "object", "properties": [
                "title": ["type": "string"], "dueDate": ["type": ["string", "null"]],
                "hasTime": ["type": "boolean"], "needsReview": ["type": "boolean"], "notes": ["type": "string"]
            ], "required": ["title", "dueDate", "hasTime", "needsReview", "notes"], "additionalProperties": false]
        }
    }
}

enum ProcessingError: Error, LocalizedError, Equatable, Sendable {
    case missingKey, invalidKey, restricted, billing, rateLimited, unavailableModel
    case offline, timeout, invalidResponse, refused, incomplete, unsupported, inputTooLong
    case configurationChanged, keychain(Int32), invalidKeyFormat, invalidOutput

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Save an API key for this provider first."
        case .invalidKey: return "The provider rejected this key. Check or replace it."
        case .restricted: return "This key or account cannot access that operation. Model listing and model use may have different permissions."
        case .billing: return "The provider reports a billing or credit limit. Check your provider account."
        case .rateLimited: return "The provider is limiting requests. Wait a little before trying again."
        case .unavailableModel: return "This exact model is unavailable to your account. Your model selection has been kept."
        case .offline: return "Could not reach the provider. Check your connection. Cached models are still available."
        case .timeout: return "The provider took too long to respond. Your original text is still available."
        case .invalidResponse: return "The provider returned an unexpected response. Your original text is still available."
        case .refused: return "The model declined this request. Your original text is still available."
        case .incomplete: return "The model did not finish its response. Incomplete text will not be inserted."
        case .unsupported: return "This model does not support the requested operation or settings. Choose a compatible model or adjust its options."
        case .inputTooLong: return "This text is too long to process in one request. Shorten it or use the original."
        case .configurationChanged: return "Processing settings changed. The old result was discarded."
        case .keychain: return "macOS Keychain could not complete this action. The saved key has not been replaced."
        case .invalidKeyFormat: return "Enter a key without spaces or line breaks."
        case .invalidOutput: return "The result changed protected details or had an unexpected format. Review the original text instead."
        }
    }

    static func sanitized(_ error: Error) -> String {
        if error is CancellationError { return "Cancelled." }
        return (error as? ProcessingError)?.errorDescription ?? "The operation could not be completed. Try again."
    }
}
