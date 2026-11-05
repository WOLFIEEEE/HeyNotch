import Foundation

struct ProviderHTTPResponse: Sendable {
    let data: Data
    let status: Int
    var retryAfter: TimeInterval? = nil
}

protocol ProviderHTTPTransport: Sendable {
    func load(_ request: URLRequest) async throws -> ProviderHTTPResponse
}

private final class ProviderSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward credentials or transcripts through a redirect.
    }
}

struct URLSessionProviderTransport: ProviderHTTPTransport {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: ProviderSessionDelegate(), delegateQueue: nil)
    }
    func load(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw ProcessingError.invalidResponse }
            guard response.expectedContentLength <= 8 * 1024 * 1024 else { throw ProcessingError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 8 * 1024 * 1024 else { throw ProcessingError.invalidResponse }
                data.append(byte)
            }
            return ProviderHTTPResponse(data: data, status: response.statusCode,
                                        retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw ProcessingError.timeout }
            throw ProcessingError.offline
        }
    }
}

struct ProviderAPI: Sendable {
    let transport: any ProviderHTTPTransport
    init(transport: any ProviderHTTPTransport = URLSessionProviderTransport()) { self.transport = transport }

    func verifyOpenRouterKey(_ snapshot: ProcessingSnapshot) async throws {
        _ = try await json(request(snapshot, path: "/key"), metadata: true)
    }

    func models(_ snapshot: ProcessingSnapshot) async throws -> [ProcessingModel] {
        var all: [String: ProcessingModel] = [:]
        var cursor: String?
        var visited: Set<String> = []
        for _ in 0..<100 {
            var path = snapshot.provider == .openrouter ? "/models/user" : "/models"
            if snapshot.provider == .anthropic {
                path += "?limit=1000"
                if let cursor {
                    var components = URLComponents()
                    components.queryItems = [URLQueryItem(name: "after_id", value: cursor)]
                    path += "&" + (components.percentEncodedQuery ?? "")
                }
            }
            let object = try await json(request(snapshot, path: path), metadata: true)
            guard let models = object["data"] as? [[String: Any]] else { throw ProcessingError.invalidResponse }
            for value in models {
                if let model = Self.parseModel(value, provider: snapshot.provider) { all[model.id] = model }
            }
            if snapshot.provider != .anthropic || object["has_more"] as? Bool != true {
                return all.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            guard let next = object["last_id"] as? String, !next.isEmpty, visited.insert(next).inserted else { throw ProcessingError.invalidResponse }
            cursor = next
            try Task.checkCancellation()
        }
        throw ProcessingError.invalidResponse // Never publish a silently partial catalogue.
    }

    func generate(_ snapshot: ProcessingSnapshot, instruction: String, input: String,
                  schema: ProcessingSchema? = nil, tokenLimit: Int? = nil) async throws -> ProcessingOutput {
        guard !snapshot.configuration.modelID.isEmpty, snapshot.model.canSelect else { throw ProcessingError.unavailableModel }
        guard input.utf8.count <= 65_536 else { throw ProcessingError.inputTooLong }
        if schema != nil && snapshot.model.structuredSupport == .unsupported { throw ProcessingError.unsupported }
        let maxTokens = min(tokenLimit ?? snapshot.configuration.outputTokenLimit, snapshot.model.outputLimit ?? 16_384)
        let model = snapshot.configuration.modelID
        var body: [String: Any]
        let path: String
        switch snapshot.provider {
        case .anthropic:
            path = "/messages"
            body = ["model": model, "max_tokens": maxTokens, "system": instruction,
                    "messages": [["role": "user", "content": input]], "stream": false]
            if let schema { body["output_config"] = ["format": ["type": "json_schema", "schema": schema.json]] }
        case .openai:
            path = "/responses"
            body = ["model": model, "instructions": instruction, "input": input,
                    "store": false, "stream": false, "max_output_tokens": maxTokens, "truncation": "disabled"]
            if let schema { body["text"] = ["format": ["type": "json_schema", "name": "heynotch_result", "strict": true, "schema": schema.json]] }
        case .openrouter:
            path = "/chat/completions"
            body = ["model": model, "max_tokens": maxTokens, "stream": false,
                    "messages": [["role": "system", "content": instruction], ["role": "user", "content": input]]]
            if let schema {
                body["response_format"] = ["type": "json_schema", "json_schema": ["name": "heynotch_result", "strict": true, "schema": schema.json]]
                body["provider"] = ["require_parameters": true]
            }
        }
        if snapshot.model.supportedParameters.contains("temperature"), let temperature = snapshot.configuration.temperature {
            body["temperature"] = min(1, max(0, temperature))
        }
        var request = request(snapshot, path: path)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try Self.parseOutput(try await json(request, metadata: false), provider: snapshot.provider)
    }

    private func request(_ snapshot: ProcessingSnapshot, path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: snapshot.provider.baseURL + path)!)
        request.timeoutInterval = min(60, max(5, snapshot.timeout))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(snapshot.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let context = snapshot.configuration.accountContext
        if snapshot.provider == .anthropic {
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            if !context.isEmpty { request.setValue(context, forHTTPHeaderField: "anthropic-workspace-id") }
        } else if snapshot.provider == .openai && !context.isEmpty {
            request.setValue(context, forHTTPHeaderField: "OpenAI-Project")
        }
        return request
    }

    private func json(_ request: URLRequest, metadata: Bool) async throws -> [String: Any] {
        for attempt in 0..<(metadata ? 3 : 1) {
            try Task.checkCancellation()
            let response = try await withThrowingTaskGroup(of: ProviderHTTPResponse.self) { group in
                group.addTask { try await transport.load(request) }
                group.addTask {
                    try await Task.sleep(for: .seconds(request.timeoutInterval))
                    throw ProcessingError.timeout
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
            if metadata && attempt < 2 && (response.status == 429 || (500...599).contains(response.status)) {
                try await Task.sleep(for: .seconds(min(2, max(0.2, response.retryAfter ?? Double(attempt + 1) * 0.4))))
                continue
            }
            let object = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
            guard (200...299).contains(response.status) else { throw Self.apiError(response.status, object: object) }
            guard let object, object["error"] == nil else { throw Self.apiError(response.status, object: object) }
            return object
        }
        throw ProcessingError.rateLimited
    }

    static func apiError(_ status: Int, object: [String: Any]?) -> ProcessingError {
        let error = object?["error"] as? [String: Any]
        let code = (error?["code"] as? String ?? error?["type"] as? String ?? "").lowercased()
        if ["insufficient_quota", "credit_balance_too_low", "billing_error"].contains(code) || status == 402 { return .billing }
        if code == "model_not_found" || status == 404 { return .unavailableModel }
        switch status {
        case 401: return .invalidKey
        case 403: return .restricted
        case 408, 504: return .timeout
        case 429: return .rateLimited
        case 400, 422: return .unsupported
        case 500...599: return .offline
        default: return .invalidResponse
        }
    }

    static func parseModel(_ object: [String: Any], provider: ProcessingProvider) -> ProcessingModel? {
        guard let id = object["id"] as? String, !id.isEmpty else { return nil }
        var model = ProcessingModel(id: id, name: object["display_name"] as? String ?? object["name"] as? String ?? id,
                                     publisher: object["owned_by"] as? String)
        switch provider {
        case .anthropic:
            model.textSupport = .supported
            model.lifecycle = object["lifecycle"] as? String
            model.contextLimit = object["max_input_tokens"] as? Int
            model.outputLimit = object["max_tokens"] as? Int
            if let capabilities = object["capabilities"] as? [String: Any],
               let structured = capabilities["structured_outputs"] as? [String: Any], let supported = structured["supported"] as? Bool {
                model.structuredSupport = supported ? .supported : .unsupported
            }
        case .openai:
            let nonText = ["text-embedding", "dall-e", "gpt-image", "sora", "whisper", "tts", "omni-moderation"]
            if nonText.contains(where: id.hasPrefix) || id.contains("-realtime") || id.contains("-transcribe") || id.contains("-audio") {
                model.textSupport = .unsupported
            }
            // The models endpoint does not establish Responses/structured-output support.
            // Unknown candidates stay selectable and can be explicitly tested.
        case .openrouter:
            model.publisher = id.split(separator: "/").first.map(String.init)
            let architecture = object["architecture"] as? [String: Any]
            if let inputs = architecture?["input_modalities"] as? [String], let outputs = architecture?["output_modalities"] as? [String] {
                model.textSupport = inputs.contains("text") && outputs.contains("text") ? .supported : .unsupported
            }
            if ["openrouter/auto", "openrouter/free", "openrouter/bodybuilder"].contains(id) || id.hasPrefix("@preset/") || id.contains(":random") {
                model.textSupport = .unsupported
            }
            model.supportedParameters = object["supported_parameters"] as? [String] ?? []
            model.structuredSupport = model.supportedParameters.contains("structured_outputs") ? .supported : .unknown
            model.contextLimit = object["context_length"] as? Int
            model.outputLimit = (object["top_provider"] as? [String: Any])?["max_completion_tokens"] as? Int
            let pricing = object["pricing"] as? [String: Any]
            func price(_ key: String) -> Double? {
                guard let string = pricing?[key] as? String, let value = Double(string), value.isFinite, value >= 0 else { return nil }
                return value * 1_000_000
            }
            model.inputPricePerMillion = price("prompt")
            model.outputPricePerMillion = price("completion")
        }
        if let limit = model.outputLimit, limit <= 0 { model.outputLimit = nil }
        if let limit = model.contextLimit, limit <= 0 { model.contextLimit = nil }
        return model
    }

    static func parseOutput(_ object: [String: Any], provider: ProcessingProvider) throws -> ProcessingOutput {
        var text = ""
        let usage = object["usage"] as? [String: Any]
        switch provider {
        case .anthropic:
            guard let stop = object["stop_reason"] as? String else { throw ProcessingError.invalidResponse }
            if stop == "refusal" { throw ProcessingError.refused }
            guard stop == "end_turn" || stop == "stop_sequence" else { throw ProcessingError.incomplete }
            let content = object["content"] as? [[String: Any]] ?? []
            text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        case .openai:
            guard object["status"] as? String == "completed" else { throw ProcessingError.incomplete }
            for item in object["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
                for part in item["content"] as? [[String: Any]] ?? [] {
                    if part["type"] as? String == "refusal" { throw ProcessingError.refused }
                    if part["type"] as? String == "output_text", let fragment = part["text"] as? String { text += fragment }
                }
            }
        case .openrouter:
            guard let choice = (object["choices"] as? [[String: Any]])?.first else { throw ProcessingError.invalidResponse }
            if choice["finish_reason"] as? String == "content_filter" { throw ProcessingError.refused }
            guard choice["finish_reason"] as? String == "stop" else { throw ProcessingError.incomplete }
            let message = choice["message"] as? [String: Any]
            if let refusal = message?["refusal"] as? String, !refusal.isEmpty { throw ProcessingError.refused }
            text = message?["content"] as? String ?? ""
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 131_072 else { throw ProcessingError.invalidResponse }
        return ProcessingOutput(text: text, inputTokens: usage?[provider == .openrouter ? "prompt_tokens" : "input_tokens"] as? Int,
                                 outputTokens: usage?[provider == .openrouter ? "completion_tokens" : "output_tokens"] as? Int)
    }
}
