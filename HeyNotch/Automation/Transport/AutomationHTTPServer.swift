import Foundation
import Network

/// A private transport between the bundled stdio bridge and the app. This is
/// deliberately not an HTTP MCP endpoint and never binds a public interface.
struct AutomationHTTPRequest {
    let clientID: String
    let token: String
    let body: Data

    enum ParseResult { case incomplete, invalid, request(AutomationHTTPRequest) }
    static let maximumBody = 65_536
    static let maximumHeaders = 8_192

    static func parse(_ data: Data) -> ParseResult {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maximumHeaders ? .invalid : .incomplete
        }
        guard boundary.lowerBound <= maximumHeaders,
              let header = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = header.components(separatedBy: "\r\n")
        guard lines.first == "POST /v1/command HTTP/1.1" else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { return .invalid }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }), headers[name] == nil else { return .invalid }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["origin"] == nil, headers["transfer-encoding"] == nil,
              headers["host"] == "127.0.0.1:49371",
              headers["content-type"]?.lowercased() == "application/json",
              let countText = headers["content-length"], !countText.isEmpty,
              countText.utf8.allSatisfy({ (48...57).contains($0) }),
              let count = Int(countText), (1...maximumBody).contains(count),
              let authorization = headers["authorization"], authorization.hasPrefix("Bearer "),
              let clientID = headers["x-heynotch-client"], UUID(uuidString: clientID) != nil else { return .invalid }
        let token = String(authorization.dropFirst(7))
        guard (32...128).contains(token.utf8.count), token.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { return .invalid }
        let body = data[boundary.upperBound...]
        guard body.count <= count else { return .invalid }
        guard body.count == count else { return .incomplete }
        return .request(AutomationHTTPRequest(clientID: clientID, token: token, body: Data(body)))
    }
}

/// All connection state lives on one utility queue. There is no polling timer.
final class AutomationHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (AutomationHTTPRequest) async -> Data
    private let queue = DispatchQueue(label: "com.wolfieeee.heynotch.automation", qos: .utility)
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var deadlines: [UUID: DispatchSourceTimer] = [:]
    // Closing a socket must not free an accepted command's slot. The command
    // can still be queued in EventKit or have committed a write.
    private var inFlightRequests: Set<UUID> = []
    private var generation = UUID()
    private let handler: Handler
    private let status: @Sendable (String) -> Void

    init(handler: @escaping Handler, status: @escaping @Sendable (String) -> Void) {
        self.handler = handler; self.status = status
    }

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 49371)
                parameters.allowLocalEndpointReuse = false
                let server = try NWListener(using: parameters)
                let current = UUID(); generation = current
                server.stateUpdateHandler = { [weak self] state in
                    guard let self, self.generation == current else { return }
                    switch state {
                    case .ready: self.status("Ready for connections on this Mac.")
                    case .failed: self.stopOnQueue(); self.status("Could not open the local connection. Another app may be using port 49371. Turn access off and on to retry.")
                    default: break
                    }
                }
                server.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener = server; server.start(queue: queue)
            } catch { status("Could not start the local connection. Turn access off and on to retry.") }
        }
    }

    func stop() { queue.async { [self] in stopOnQueue(); status("Agent access is off.") } }
    private func stopOnQueue() {
        generation = UUID(); listener?.cancel(); listener = nil
        deadlines.values.forEach { $0.cancel() }; deadlines.removeAll()
        let old = connections.values; connections.removeAll()
        old.forEach { $0.cancel() }
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state { case .failed, .cancelled: self?.close(id); default: break }
        }
        connection.start(queue: queue)
        // Bounded slow-client lifetime. Closing a connection never rolls back a
        // command already accepted by the engine; callers recover by operationID.
        let deadline = DispatchSource.makeTimerSource(queue: queue)
        deadline.schedule(deadline: .now() + 60)
        deadline.setEventHandler { [weak self] in self?.close(id) }
        deadlines[id] = deadline; deadline.resume()
        receive(id, data: Data())
    }
    private func receive(_ id: UUID, data: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] bytes, _, finished, error in
            guard let self, self.connections[id] != nil else { return }
            var accumulated = data
            if let bytes { accumulated.append(bytes) }
            guard accumulated.count <= AutomationHTTPRequest.maximumHeaders + AutomationHTTPRequest.maximumBody + 4 else {
                self.respond(id, status: 400, body: Self.error("invalid_request", "Request is too large.")); return
            }
            switch AutomationHTTPRequest.parse(accumulated) {
            case .invalid: self.respond(id, status: 400, body: Self.error("invalid_request", "Invalid local request."))
            case .incomplete:
                if finished || error != nil { self.close(id) } else { self.receive(id, data: accumulated) }
            case .request(let request):
                guard self.inFlightRequests.count < 8 else {
                    self.respond(id, status: 200, body: Self.error("busy", "Eight commands are already in progress. This command was not accepted."))
                    return
                }
                self.inFlightRequests.insert(id)
                let current = self.generation
                Task {
                    let body = await self.handler(request)
                    self.queue.async { [weak self] in
                        guard let self else { return }
                        self.inFlightRequests.remove(id)
                        guard self.generation == current else { return }
                        self.respond(id, status: 200, body: body)
                    }
                }
            }
        }
    }
    private func respond(_ id: UUID, status: Int, body: Data) {
        guard let connection = connections[id] else { return }
        var response = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Bad Request")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.close(id) })
    }
    private func close(_ id: UUID) {
        deadlines.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }
    static func error(_ code: String, _ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": ["code": code, "message": message]])) ?? Data()
    }
}
