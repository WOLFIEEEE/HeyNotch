import Foundation

private enum RequestID: Hashable, Sendable {
    case string(String), integer(Int64)
    init?(_ value: JSONValue?) {
        switch value {
        case .string(let text) where text.utf8.count <= 256: self = .string(text)
        case .integer(let number): self = .integer(number)
        default: return nil
        }
    }
    var json: JSONValue { switch self { case .string(let v): return .string(v); case .integer(let v): return .integer(v) } }
}

public actor MCPServer {
    public static let protocolVersion = "2025-11-25"
    private enum State { case fresh, awaitingInitialized, ready, closed }
    private var state: State = .fresh
    private let transport: any BrokerTransport
    private let output: @Sendable (JSONValue) -> Void
    private struct Pending { let generation: UUID; let task: Task<Void, Never> }
    private var pending: [RequestID: Pending] = [:]

    public init(transport: any BrokerTransport, output: @escaping @Sendable (JSONValue) -> Void) {
        self.transport = transport; self.output = output
    }
    public var pendingCount: Int { pending.count }
    public func receive(_ data: Data) {
        guard state != .closed else { return }
        guard data.count <= BridgeLimits.inputLine, String(data: data, encoding: .utf8) != nil,
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            error(nil, -32700, "Invalid UTF-8 JSON message."); return
        }
        guard let message = decoded.object, message["jsonrpc"] == .string("2.0") else {
            error(nil, -32600, "Expected one JSON-RPC 2.0 object."); return
        }
        // This server sends no client requests; unsolicited responses require no response.
        if message["method"] == nil && (message["result"] != nil || message["error"] != nil) { return }
        guard let method = message["method"]?.string, !method.isEmpty, method.utf8.count <= 128 else {
            error(RequestID(message["id"]), -32600, "Invalid request method."); return
        }
        let id = RequestID(message["id"])
        if message["id"] != nil && id == nil { error(nil, -32600, "Request ID must be an integer or a string of at most 256 bytes."); return }
        guard let id else {
            if method == "notifications/initialized", state == .awaitingInitialized,
               message["params"] == nil || message["params"]?.object != nil { state = .ready }
            if method == "notifications/cancelled", let cancelled = RequestID(message["params"]?["requestId"]) {
                pending.removeValue(forKey: cancelled)?.task.cancel()
            }
            // Notifications never execute tools and never receive responses.
            return
        }
        guard pending[id] == nil else { error(id, -32600, "Request ID is already in flight."); return }
        if let params = message["params"], params.object == nil { error(id, -32602, "Request params must be an object."); return }
        let params = message["params"]?.object ?? [:]
        switch method {
        case "initialize":
            guard state == .fresh else { error(id, -32600, "This connection has already initialized."); return }
            guard let version = params["protocolVersion"]?.string, !version.isEmpty,
                  params["capabilities"]?.object != nil,
                  let info = params["clientInfo"]?.object, info["name"]?.string != nil, info["version"]?.string != nil else {
                error(id, -32602, "initialize requires protocolVersion, capabilities and clientInfo name/version."); return
            }
            state = .awaitingInitialized
            result(id, .object(["protocolVersion": .string(Self.protocolVersion), "capabilities": .object(["tools": .object([:])]),
                                "serverInfo": .object(["name": .string("heynotch-mcp"), "version": .string("1.0.0")]),
                                "instructions": .string(ToolCatalog.instructions)]))
        case "ping": result(id, .object([:]))
        default:
            guard state == .ready else { error(id, -32002, "Initialize and send notifications/initialized before using tools."); return }
            switch method {
            case "tools/list":
                guard params["cursor"] == nil else { error(id, -32602, "This fixed tool catalog has no pagination cursor."); return }
                result(id, .object(["tools": .array(ToolCatalog.definitions)]))
            case "tools/call":
                let arguments = params["arguments"] ?? .object([:])
                guard let name = params["name"]?.string,
                      arguments.object != nil, params["task"] == nil else {
                    error(id, -32602, "tools/call requires a tool name and object arguments; background tasks are not supported."); return
                }
                guard ToolCatalog.names.contains(name) else { error(id, -32602, "Unknown tool."); return }
                do { try ToolCatalog.validate(name: name, arguments: arguments) }
                catch let failure as BridgeFailure { result(id, toolResult(failureValue(failure, arguments: arguments))); return }
                catch { result(id, toolResult(failureValue(BridgeFailure("invalid_arguments", "Invalid tool arguments."), arguments: arguments))); return }
                guard pending.count < BridgeLimits.concurrentCalls else {
                    result(id, toolResult(failureValue(BridgeFailure("busy", "The bridge already has eight in-flight calls. This command was not sent. Retry after one finishes."), arguments: arguments))); return
                }
                let transport = self.transport
                let generation = UUID()
                let task = Task { [weak self] in
                    let value: JSONValue
                    do { value = try await transport.execute(tool: name, arguments: arguments) }
                    catch is CancellationError { await self?.discard(id, generation: generation); return }
                    catch let failure as BridgeFailure { value = Self.failureValue(failure, arguments: arguments) }
                    catch { value = Self.failureValue(BridgeFailure("bridge_error", "The command did not return a usable result. For writes, reconcile the original operationID before retrying."), arguments: arguments) }
                    guard !Task.isCancelled else { await self?.discard(id, generation: generation); return }
                    await self?.complete(id, generation: generation, value: value)
                }
                pending[id] = Pending(generation: generation, task: task)
            default: error(id, -32601, "Method not found.")
            }
        }
    }
    public func framingError() { error(nil, -32700, "Input line exceeded its bound or ended without a newline.") }
    public func shutdown() {
        state = .closed
        for item in pending.values { item.task.cancel() }
        pending.removeAll()
    }
    private func complete(_ id: RequestID, generation: UUID, value: JSONValue) {
        guard state != .closed, pending[id]?.generation == generation else { return }
        pending.removeValue(forKey: id)
        result(id, toolResult(value))
    }
    private func discard(_ id: RequestID, generation: UUID) {
        if pending[id]?.generation == generation { pending.removeValue(forKey: id) }
    }
    private func result(_ id: RequestID, _ value: JSONValue) {
        output(.object(["jsonrpc": .string("2.0"), "id": id.json, "result": value]))
    }
    private func error(_ id: RequestID?, _ code: Int64, _ message: String) {
        output(.object(["jsonrpc": .string("2.0"), "id": id?.json ?? .null,
                        "error": .object(["code": .integer(code), "message": .string(message)])]))
    }
    private nonisolated func toolResult(_ value: JSONValue) -> JSONValue {
        let text = (try? value.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                        "structuredContent": value, "isError": .bool(value["ok"]?.boolean != true)])
    }
    private nonisolated func failureValue(_ failure: BridgeFailure, arguments: JSONValue) -> JSONValue { Self.failureValue(failure, arguments: arguments) }
    private static func failureValue(_ failure: BridgeFailure, arguments: JSONValue) -> JSONValue {
        var fields: [String: JSONValue] = ["ok": .bool(false), "error": .object(["code": .string(failure.code), "message": .string(failure.message)])]
        if let operation = arguments["operationID"]?.string { fields["operationID"] = .string(operation) }
        return .object(fields)
    }
}

public struct StdioFramer {
    private var buffer = Data()
    public init() {}
    public var hasPartialLine: Bool { !buffer.isEmpty }
    public mutating func append(_ byte: UInt8) throws -> Data? {
        if byte == 10 {
            if buffer.last == 13 { buffer.removeLast() }
            let line = buffer; buffer.removeAll(keepingCapacity: true); return line
        }
        guard buffer.count < BridgeLimits.inputLine else { throw BridgeFailure("input_limit", "Input line is too large.") }
        buffer.append(byte); return nil
    }
}
