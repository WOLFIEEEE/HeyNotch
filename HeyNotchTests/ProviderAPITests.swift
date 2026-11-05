import Foundation
import XCTest

final class ProviderAPITests: XCTestCase {
    private func snapshot(_ provider: ProcessingProvider, model: String = "chosen-exact-model") -> ProcessingSnapshot {
        var configuration = ProviderConfiguration()
        configuration.modelID = model
        configuration.accountContext = "workspace-or-project"
        return ProcessingSnapshot(provider: provider, configuration: configuration, model: .manual(model),
                                   key: "fixture-secret", timeout: 15, preferencesRevision: UUID())
    }

    func testClaudePaginationAuthenticationAndDeduplication() async throws {
        let transport = FixtureProviderTransport([
            .json(["data": [["id": "claude-one", "display_name": "One"]], "has_more": true, "last_id": "claude-one"]),
            .json(["data": [["id": "claude-one"], ["id": "claude-two"]], "has_more": false])
        ])
        let models = try await ProviderAPI(transport: transport).models(snapshot(.anthropic))
        XCTAssertEqual(Set(models.map(\.id)), ["claude-one", "claude-two"])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "anthropic-workspace-id"), "workspace-or-project")
        XCTAssertTrue(requests[1].url!.absoluteString.contains("after_id=claude-one"))
    }

    func testRepeatedPaginationCursorIsRejectedWithoutPartialCatalog() async throws {
        let page = ProviderHTTPResponse.json(["data": [["id": "a"]], "has_more": true, "last_id": "a"])
        let transport = FixtureProviderTransport([page, page])
        do { _ = try await ProviderAPI(transport: transport).models(snapshot(.anthropic)); XCTFail("Accepted looping cursor") }
        catch { XCTAssertEqual(error as? ProcessingError, .invalidResponse) }
    }

    func testOpenAIUsesResponsesAndExactModelWithoutStorage() async throws {
        let transport = FixtureProviderTransport([.json([
            "status": "completed", "output": [["type": "reasoning", "summary": []],
                ["type": "message", "content": [["type": "output_text", "text": "Clean text."]]]],
            "usage": ["input_tokens": 5, "output_tokens": 3]
        ])])
        let output = try await ProviderAPI(transport: transport).generate(snapshot(.openai), instruction: "Transform", input: "private transcript")
        XCTAssertEqual(output.text, "Clean text.")
        XCTAssertEqual(output.inputTokens, 5)
        let firstRequest = await transport.firstRequest()
        let request = try XCTUnwrap(firstRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Project"), "workspace-or-project")
        let body = try body(request)
        XCTAssertEqual(body["model"] as? String, "chosen-exact-model")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["input"] as? String, "private transcript")
        XCTAssertNil(body["temperature"])
    }

    func testClaudeMessagesUsesSeparateSystemAndTextBlocks() async throws {
        let transport = FixtureProviderTransport([.json(["stop_reason": "end_turn", "content": [["type": "thinking", "thinking": "hidden"], ["type": "text", "text": "Result"]]])])
        let output = try await ProviderAPI(transport: transport).generate(snapshot(.anthropic), instruction: "System policy", input: "Input data", schema: .probe)
        XCTAssertEqual(output.text, "Result")
        let firstRequest = await transport.firstRequest()
        let request = try XCTUnwrap(firstRequest)
        XCTAssertEqual(request.url?.path, "/v1/messages")
        let body = try body(request)
        XCTAssertEqual(body["system"] as? String, "System policy")
        XCTAssertNotNil(body["output_config"])
        XCTAssertNil(body["response_format"])
        XCTAssertNil(body["store"])
    }

    func testOpenRouterUsesNamespacedModelAndRequiresStructuredParameters() async throws {
        let transport = FixtureProviderTransport([.json(["choices": [["finish_reason": "stop", "message": ["content": "{\"text\":\"Hello\"}"]]]])])
        _ = try await ProviderAPI(transport: transport).generate(snapshot(.openrouter, model: "publisher/model:exact"), instruction: "Transform", input: "Data", schema: .probe)
        let firstRequest = await transport.firstRequest()
        let request = try XCTUnwrap(firstRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        let body = try body(request)
        XCTAssertEqual(body["model"] as? String, "publisher/model:exact")
        XCTAssertEqual((body["provider"] as? [String: Any])?["require_parameters"] as? Bool, true)
        XCTAssertNotNil(body["response_format"])
        XCTAssertNil(body["models"])
        XCTAssertNil(body["route"])
    }

    func testOpenRouterVerifiesKeySeparatelyFromCatalog() async throws {
        let transport = FixtureProviderTransport([.json(["data": ["label": "fixture"]]), .json(["data": []])])
        let api = ProviderAPI(transport: transport)
        try await api.verifyOpenRouterKey(snapshot(.openrouter))
        _ = try await api.models(snapshot(.openrouter))
        let paths = await transport.requests.compactMap { $0.url?.path }
        XCTAssertEqual(paths, ["/api/v1/key", "/api/v1/models/user"])
    }

    func testRefusalsAndIncompleteOutputsCannotBecomeInsertionText() {
        XCTAssertThrowsError(try ProviderAPI.parseOutput(["status": "completed", "output": [["type": "message", "content": [["type": "refusal", "refusal": "no"]]]]], provider: .openai)) {
            XCTAssertEqual($0 as? ProcessingError, .refused)
        }
        XCTAssertThrowsError(try ProviderAPI.parseOutput(["stop_reason": "max_tokens", "content": [["type": "text", "text": "partial"]]], provider: .anthropic)) {
            XCTAssertEqual($0 as? ProcessingError, .incomplete)
        }
        XCTAssertThrowsError(try ProviderAPI.parseOutput(["choices": [["finish_reason": "length", "message": ["content": "partial"]]]], provider: .openrouter)) {
            XCTAssertEqual($0 as? ProcessingError, .incomplete)
        }
    }

    func testGenerationIsNeverAutomaticallyRetried() async {
        let transport = FixtureProviderTransport([.json(["error": ["message": "fixture-secret private transcript"]], status: 429)])
        do { _ = try await ProviderAPI(transport: transport).generate(snapshot(.openai), instruction: "Transform", input: "text"); XCTFail() }
        catch {
            XCTAssertEqual(error as? ProcessingError, .rateLimited)
            XCTAssertFalse(ProcessingError.sanitized(error).contains("fixture-secret"))
            XCTAssertFalse(ProcessingError.sanitized(error).contains("private transcript"))
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testBillingAndRestrictedDiscoveryAreNotReportedAsInvalidKeys() {
        XCTAssertEqual(ProviderAPI.apiError(429, object: ["error": ["code": "insufficient_quota"]]), .billing)
        XCTAssertEqual(ProviderAPI.apiError(403, object: nil), .restricted)
        XCTAssertEqual(ProviderAPI.apiError(401, object: nil), .invalidKey)
    }

    func testUnknownTextCandidatesRemainSelectableAndKnownNonTextModelsDoNot() throws {
        let future = try XCTUnwrap(ProviderAPI.parseModel(["id": "brand-new-model"], provider: .openai))
        XCTAssertTrue(future.canSelect)
        XCTAssertEqual(future.structuredSupport, .unknown)
        XCTAssertFalse(try XCTUnwrap(ProviderAPI.parseModel(["id": "text-embedding-3-large"], provider: .openai)).canSelect)
        XCTAssertFalse(try XCTUnwrap(ProviderAPI.parseModel(["id": "openrouter/auto"], provider: .openrouter)).canSelect)
        XCTAssertFalse(try XCTUnwrap(ProviderAPI.parseModel(["id": "retired", "lifecycle": "retired"], provider: .anthropic)).canSelect)
    }

    func testRouterCapabilitiesAndPricesAreReadFromMetadata() throws {
        let model = try XCTUnwrap(ProviderAPI.parseModel(["id": "publisher/model", "name": "A model",
            "architecture": ["input_modalities": ["text"], "output_modalities": ["text"]],
            "supported_parameters": ["structured_outputs", "temperature"],
            "pricing": ["prompt": "0.000001", "completion": "0.000002"]], provider: .openrouter))
        XCTAssertEqual(model.structuredSupport, .supported)
        XCTAssertEqual(model.inputPricePerMillion, 1)
        XCTAssertEqual(model.outputPricePerMillion, 2)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
}

actor FixtureProviderTransport: ProviderHTTPTransport {
    private var responses: [ProviderHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [ProviderHTTPResponse]) { self.responses = responses }
    func load(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw ProcessingError.offline }
        return responses.removeFirst()
    }
    func firstRequest() -> URLRequest? { requests.first }
}

extension ProviderHTTPResponse {
    static func json(_ object: [String: Any], status: Int = 200) -> Self {
        Self(data: try! JSONSerialization.data(withJSONObject: object), status: status)
    }
}
