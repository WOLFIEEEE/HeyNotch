import Darwin
import Foundation
import XCTest
@testable import HeyNotchMCPCore

final class ConnectionTests: XCTestCase {
    let token = String(repeating: "a", count: 43)
    func data(endpoint: String = "http://127.0.0.1:49371", token: String? = nil) throws -> Data {
        try JSONValue.object(["version": .integer(1), "endpoint": .string(endpoint),
                              "clientID": .string("5F101939-4497-457C-8679-BFF895BDA828"), "token": .string(token ?? self.token)]).encoded()
    }
    func withFile(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("connection.json")
        try data().write(to: file); chmod(file.path, 0o600)
        try body(file)
    }
    func testValidPrivateFileAndRedactedFailures() throws {
        try withFile { file in
            let connection = try BridgeConnection.load(path: file.path)
            XCTAssertEqual(connection.endpoint.port, 49371)
            XCTAssertEqual(connection.clientID, "5F101939-4497-457C-8679-BFF895BDA828")
            chmod(file.path, 0o644)
            XCTAssertThrowsError(try BridgeConnection.load(path: file.path)) { error in
                XCTAssertFalse((error as! BridgeFailure).message.contains(self.token))
            }
        }
    }
    func testSymlinkHardlinkAndFIFORejectedWithoutBlocking() throws {
        try withFile { file in
            let link = file.deletingLastPathComponent().appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            XCTAssertThrowsError(try BridgeConnection.load(path: link.path))
            try FileManager.default.removeItem(at: link)
            try FileManager.default.linkItem(at: file, to: link)
            XCTAssertThrowsError(try BridgeConnection.load(path: file.path))
            try FileManager.default.removeItem(at: link)
            XCTAssertEqual(mkfifo(link.path, 0o600), 0)
            XCTAssertThrowsError(try BridgeConnection.load(path: link.path))
        }
    }
    func testOwnerModeAndSizeAreStrict() throws {
        var attributes = stat(); attributes.st_mode = S_IFREG | 0o600
        attributes.st_uid = geteuid(); attributes.st_nlink = 1; attributes.st_size = 100
        XCTAssertTrue(BridgeConnection.safe(attributes))
        attributes.st_uid = geteuid() &+ 1; XCTAssertFalse(BridgeConnection.safe(attributes))
        attributes.st_uid = geteuid(); attributes.st_mode = S_IFREG | 0o400; XCTAssertFalse(BridgeConnection.safe(attributes))
        try withFile { file in
            try Data(repeating: 32, count: BridgeLimits.credentialFile + 1).write(to: file)
            XCTAssertThrowsError(try BridgeConnection.load(path: file.path))
        }
    }
    func testOnlyCanonicalLoopbackEndpointAccepted() throws {
        for endpoint in ["https://127.0.0.1:49371", "http://localhost:49371", "http://127.0.0.1:49371/", "http://127.0.0.1:49371/a", "http://127.0.0.1:49371?x", "http://127.0.0.1:49371#x", "http://127.0.0.1:049371", "http://127.0.0.1:0", "http://127.0.0.1:65536", "http://127.0.0.1:49371@evil.test", "http://127.0.0.1:49371\n"] {
            XCTAssertThrowsError(try BridgeConnection.decode(data(endpoint: endpoint)), endpoint)
        }
        XCTAssertEqual(try BridgeConnection.decode(data(endpoint: "http://127.0.0.1:12345")).endpoint.port, 12345)
        XCTAssertThrowsError(try BridgeConnection.decode(data(token: token + "\r\nX: bad")))
    }
    func testVersionAndFieldsMustMatch() throws {
        var value = try JSONDecoder().decode(JSONValue.self, from: data()).object!
        value["version"] = .bool(true)
        XCTAssertThrowsError(try BridgeConnection.decode(JSONValue.object(value).encoded()))
        value["version"] = .integer(1); value["extra"] = .string("ignored?")
        XCTAssertThrowsError(try BridgeConnection.decode(JSONValue.object(value).encoded()))
    }
}

final class FramingAndSchemaTests: XCTestCase {
    func testFramingUnicodeCRLFAndBound() throws {
        var framer = StdioFramer(); var lines: [Data] = []
        for byte in Data("{\"text\":\"café 👋\"}\r\n{}\n".utf8) { if let line = try framer.append(byte) { lines.append(line) } }
        XCTAssertEqual(lines.count, 2); XCTAssertFalse(framer.hasPartialLine)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: lines[0])["text"], .string("café 👋"))
        for _ in 0..<BridgeLimits.inputLine { _ = try framer.append(32) }
        XCTAssertThrowsError(try framer.append(32)); XCTAssertTrue(framer.hasPartialLine)
    }
    func testCatalogHasNineToolsAndReadWriteAnnotations() throws {
        XCTAssertEqual(ToolCatalog.definitions.count, 9); XCTAssertEqual(ToolCatalog.names.count, 9)
        for tool in ToolCatalog.definitions {
            XCTAssertEqual(tool["annotations"]?["readOnlyHint"]?.boolean, !ToolCatalog.writeTools.contains(tool["name"]!.string!))
            XCTAssertNoThrow(try tool.encoded())
        }
    }
    func testWritesRequireUUIDAndRevisionAndRejectUnknownFields() throws {
        let args: [String: JSONValue] = ["operationID": .string(UUID().uuidString), "taskID": .string("task"), "expectedRevision": .string(String(repeating: "a", count: 64)), "column": .string("doing")]
        XCTAssertNoThrow(try ToolCatalog.validate(name: "move_task", arguments: .object(args)))
        for key in args.keys { var copy = args; copy.removeValue(forKey: key); XCTAssertThrowsError(try ToolCatalog.validate(name: "move_task", arguments: .object(copy))) }
        var invalid = args; invalid["extra"] = .bool(true)
        XCTAssertThrowsError(try ToolCatalog.validate(name: "move_task", arguments: .object(invalid)))
        invalid = args; invalid["operationID"] = .string("not-a-uuid")
        XCTAssertThrowsError(try ToolCatalog.validate(name: "move_task", arguments: .object(invalid)))
        invalid = args; invalid["expectedRevision"] = .string(String(repeating: "A", count: 64))
        XCTAssertThrowsError(try ToolCatalog.validate(name: "move_task", arguments: .object(invalid)))
    }
    func testDueCompanionsAndUTF8Limits() throws {
        var args: [String: JSONValue] = ["operationID": .string(UUID().uuidString), "listID": .string("list"), "title": .string("Call José"), "due": .object(["year": .integer(2026), "month": .integer(11), "day": .integer(5), "hour": .integer(10)])]
        XCTAssertThrowsError(try ToolCatalog.validate(name: "create_task", arguments: .object(args)))
        args["due"] = .object(["year": .integer(2026), "month": .integer(11), "day": .integer(5)])
        XCTAssertNoThrow(try ToolCatalog.validate(name: "create_task", arguments: .object(args)))
        args["title"] = .string(String(repeating: "👋", count: 1100))
        XCTAssertThrowsError(try ToolCatalog.validate(name: "create_task", arguments: .object(args)))
        args["title"] = .string("   \n")
        XCTAssertThrowsError(try ToolCatalog.validate(name: "create_task", arguments: .object(args)))
    }
}

private final class Responses: @unchecked Sendable {
    private let lock = NSLock(); private var values: [JSONValue] = []
    func append(_ value: JSONValue) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var snapshot: [JSONValue] { lock.lock(); defer { lock.unlock() }; return values }
}
private actor GateTransport: BrokerTransport {
    private var waits: [CheckedContinuation<JSONValue, Error>] = []
    var count: Int { waits.count }
    func execute(tool: String, arguments: JSONValue) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { waits.append($0) }
    }
    func finishFirst(_ value: String = "result") {
        waits.removeFirst().resume(returning: .object(["ok": .bool(true), "result": .object(["value": .string(value)])]))
    }
    func finishAll() { while !waits.isEmpty { finishFirst() } }
}

final class ServerTests: XCTestCase {
    func request(_ method: String, id: JSONValue? = .integer(1), params: JSONValue? = nil) throws -> Data {
        var value: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        value["id"] = id; value["params"] = params
        return try JSONValue.object(value).encoded()
    }
    func ready(_ server: MCPServer) async throws {
        await server.receive(try request("initialize", params: .object(["protocolVersion": .string("2025-11-25"), "capabilities": .object([:]), "clientInfo": .object(["name": .string("test"), "version": .string("1")])])))
        await server.receive(try request("notifications/initialized", id: nil))
    }
    func call(_ id: Int64) throws -> Data { try request("tools/call", id: .integer(id), params: .object(["name": .string("get_context"), "arguments": .object([:])])) }
    private func waitCount(_ transport: GateTransport, _ count: Int) async throws {
        for _ in 0..<100 { if await transport.count == count { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Transport count did not reach \(count)")
    }
    func testLifecyclePingCatalogUnknownMethodAndNotification() async throws {
        let output = Responses(); let transport = GateTransport()
        let server = MCPServer(transport: transport, output: { output.append($0) })
        await server.receive(try request("tools/list")); XCTAssertEqual(output.snapshot.last?["error"]?["code"], .integer(-32002))
        await server.receive(try request("ping", id: .string(""))); XCTAssertEqual(output.snapshot.last?["result"], .object([:]))
        try await ready(server)
        await server.receive(try request("tools/list", id: .integer(2)))
        if case .array(let tools) = output.snapshot.last?["result"]?["tools"] { XCTAssertEqual(tools.count, 9) } else { XCTFail() }
        await server.receive(try request("unknown", id: .integer(3))); XCTAssertEqual(output.snapshot.last?["error"]?["code"], .integer(-32601))
        let before = output.snapshot.count
        await server.receive(try request("tools/call", id: nil, params: .object(["name": .string("create_task")])))
        XCTAssertEqual(output.snapshot.count, before); let count = await transport.count; XCTAssertEqual(count, 0)
        await server.shutdown()
    }
    func testInvalidJSONBatchAndBooleanID() async throws {
        let output = Responses(); let server = MCPServer(transport: GateTransport(), output: { output.append($0) })
        await server.receive(Data([0xff])); XCTAssertEqual(output.snapshot.last?["error"]?["code"], .integer(-32700))
        await server.receive(Data("[]".utf8)); XCTAssertEqual(output.snapshot.last?["error"]?["code"], .integer(-32600))
        await server.receive(try request("ping", id: .bool(true))); XCTAssertEqual(output.snapshot.last?["error"]?["code"], .integer(-32600))
    }
    func testInvalidToolArgumentsNeverReachBroker() async throws {
        let output = Responses(); let transport = GateTransport(); let server = MCPServer(transport: transport, output: { output.append($0) })
        try await ready(server)
        await server.receive(try request("tools/call", id: .integer(2), params: .object(["name": .string("create_task"), "arguments": .object([:])])))
        XCTAssertEqual(output.snapshot.last?["result"]?["isError"], .bool(true))
        XCTAssertEqual(output.snapshot.last?["result"]?["structuredContent"]?["error"]?["code"], .string("invalid_arguments"))
        let count = await transport.count; XCTAssertEqual(count, 0)
    }
    func testCancellationCannotEraseReusedIDsNewRequest() async throws {
        let output = Responses(); let transport = GateTransport(); let server = MCPServer(transport: transport, output: { output.append($0) })
        try await ready(server); await server.receive(try call(2)); try await waitCount(transport, 1)
        await server.receive(try request("notifications/cancelled", id: nil, params: .object(["requestId": .integer(2)])))
        await server.receive(try call(2)); try await waitCount(transport, 2)
        await transport.finishFirst("cancelled old")
        try await Task.sleep(for: .milliseconds(20))
        let pending = await server.pendingCount; XCTAssertEqual(pending, 1)
        XCTAssertEqual(output.snapshot.count, 1)
        await transport.finishFirst("new")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(output.snapshot.last?["result"]?["structuredContent"]?["result"]?["value"], .string("new"))
        XCTAssertEqual(output.snapshot.count, 2)
    }
    func testConcurrencyBoundAndShutdownSuppressLateResponses() async throws {
        let output = Responses(); let transport = GateTransport(); let server = MCPServer(transport: transport, output: { output.append($0) })
        try await ready(server)
        for id in 2...10 { await server.receive(try call(Int64(id))) }
        try await waitCount(transport, 8)
        XCTAssertEqual(output.snapshot.last?["result"]?["structuredContent"]?["error"]?["code"], .string("busy"))
        await server.shutdown(); await transport.finishAll()
        try await Task.sleep(for: .milliseconds(20)); XCTAssertEqual(output.snapshot.count, 2)
    }
}
