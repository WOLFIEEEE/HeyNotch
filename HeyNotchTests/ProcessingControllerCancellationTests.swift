import Foundation
import XCTest

@MainActor
final class ProcessingControllerCancellationTests: XCTestCase {
    private func withController(
        holdKeyRead: Bool = false,
        _ test: (ProcessingController, ProcessingSettingsStore, CancellationKeyStore, CancellationHTTP) async throws -> Void
    ) async rethrows {
        let suite = "HeyNotchTests.processing-cancellation.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProcessingSettingsStore(defaults: defaults)
        store.update { $0.activeProvider = .openai }
        let keys = CancellationKeyStore(holdFirstRead: holdKeyRead)
        let http = CancellationHTTP()
        let controller = ProcessingController(store: store, keys: keys, api: ProviderAPI(transport: http))
        defer { controller.cancel() }
        try await test(controller, store, keys, http)
    }

    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected operation did not reach the controlled suspension", file: file, line: line)
    }

    func testCancelShowsVerificationCancelledAndRejectsLateSuccess() async throws {
        try await withController { controller, store, _, http in
            controller.refresh(.openai)
            try await waitUntil { await http.count == 1 }
            controller.cancel()
            XCTAssertFalse(controller.isWorking)
            XCTAssertEqual(controller.messages[.openai], "Verification cancelled.")
            await http.finish()
            await Task.yield()
            XCTAssertNil(store.catalog(.openai))
            XCTAssertEqual(controller.messages[.openai], "Verification cancelled.")
        }
    }

    func testCancelModelTestHasAccurateStatusAndKeepsOtherProviderResult() async throws {
        try await withController { controller, store, _, http in
            _ = await controller.saveKey("fake-anthropic-key", provider: .anthropic)
            let otherResult = controller.messages[.anthropic]
            store.configure(.openai) { $0.modelID = "fixture-model" }
            controller.testModel(.openai)
            try await waitUntil { await http.count == 1 }
            controller.cancel()
            XCTAssertEqual(controller.messages[.openai], "Model test cancelled.")
            XCTAssertEqual(controller.messages[.anthropic], otherResult)
            await http.finish()
        }
    }

    func testCancellingIdleControllerPreservesCompletedResult() async throws {
        try await withController { controller, _, _, http in
            controller.refresh(.openai)
            try await waitUntil { await http.count == 1 }
            await http.finish()
            try await waitUntil { !controller.isWorking }
            let result = controller.messages[.openai]
            XCTAssertTrue(result?.hasPrefix("Key verified.") == true)
            controller.cancel()
            XCTAssertEqual(controller.messages[.openai], result)
        }
    }

    func testPaneTaskCancellationPreventsRefreshAfterDelayedKeyRead() async throws {
        try await withController(holdKeyRead: true) { controller, store, keys, http in
            let pane = Task { await controller.preparePane(for: .openai) }
            try await waitUntil { await keys.isWaiting }
            pane.cancel()
            await keys.release()
            await pane.value
            XCTAssertFalse(controller.isWorking)
            XCTAssertNil(controller.hasKey[.openai])
            XCTAssertNil(store.catalog(.openai))
            let calls = await http.count
            XCTAssertEqual(calls, 0)
        }
    }

    func testControllerCancellationInvalidatesPendingPaneEvenIfCallerIsNotCancelled() async throws {
        try await withController(holdKeyRead: true) { controller, _, keys, http in
            let pane = Task { await controller.preparePane(for: .openai) }
            try await waitUntil { await keys.isWaiting }
            controller.cancel()
            await keys.release()
            await pane.value
            XCTAssertFalse(controller.isWorking)
            XCTAssertNil(controller.hasKey[.openai])
            let calls = await http.count
            XCTAssertEqual(calls, 0)
        }
    }

    func testLatePaneErrorCannotOverwriteNewKeySaveResult() async throws {
        try await withController(holdKeyRead: true) { controller, _, keys, http in
            let pane = Task { await controller.preparePane(for: .openai) }
            try await waitUntil { await keys.isWaiting }
            _ = await controller.saveKey("replacement-fixture", provider: .openai)
            let saved = controller.messages[.openai]
            await keys.release(error: ProcessingError.keychain(-1))
            await pane.value
            XCTAssertEqual(controller.messages[.openai], saved)
            XCTAssertEqual(controller.hasKey[.openai], true)
            let calls = await http.count
            XCTAssertEqual(calls, 0)
        }
    }

    func testVerificationCancelledDuringKeyReadNeverSendsRequest() async throws {
        try await withController(holdKeyRead: true) { controller, _, keys, http in
            controller.refresh(.openai)
            try await waitUntil { await keys.isWaiting }
            controller.cancel()
            await keys.release()
            // Release the suspended snapshot and allow its cancellation check to run.
            try await Task.sleep(for: .milliseconds(20))
            let calls = await http.count
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(controller.messages[.openai], "Verification cancelled.")
        }
    }

    func testCurrentPaneStillLoadsModelsAfterKeyRead() async throws {
        try await withController(holdKeyRead: true) { controller, store, keys, http in
            let pane = Task { await controller.preparePane(for: .openai) }
            try await waitUntil { await keys.isWaiting }
            await keys.release()
            await pane.value
            try await waitUntil { await http.count == 1 }
            await http.finish()
            try await waitUntil { !controller.isWorking }
            XCTAssertEqual(store.catalog(.openai)?.models.map(\.id), ["fixture-model"])
        }
    }
}

private actor CancellationKeyStore: ProviderKeyStoring {
    private var holdFirstRead: Bool
    private var read: CheckedContinuation<String?, Error>?
    var isWaiting: Bool { read != nil }
    init(holdFirstRead: Bool) { self.holdFirstRead = holdFirstRead }
    func read(_ provider: ProcessingProvider) async throws -> String? {
        if holdFirstRead {
            holdFirstRead = false
            return try await withCheckedThrowingContinuation { read = $0 }
        }
        return "fixture-key"
    }
    func release(error: Error? = nil) {
        let continuation = read; read = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: "fixture-key") }
    }
    func save(_ key: String, for provider: ProcessingProvider) async throws {}
    func remove(_ provider: ProcessingProvider) async throws {}
}

private actor CancellationHTTP: ProviderHTTPTransport {
    private(set) var count = 0
    private var responses: [CheckedContinuation<ProviderHTTPResponse, Never>] = []
    func load(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        count += 1
        // Deliberately non-cooperative cancellation proves late responses cannot
        // undo a cancellation or overwrite the latest status.
        return await withCheckedContinuation { responses.append($0) }
    }
    func finish() {
        let pending = responses; responses.removeAll()
        for response in pending {
            response.resume(returning: .init(data: Data("{\"data\":[{\"id\":\"fixture-model\"}]}".utf8), status: 200))
        }
    }
}
