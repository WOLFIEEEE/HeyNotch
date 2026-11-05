import Foundation

public protocol BrokerTransport: Sendable {
    func execute(tool: String, arguments: JSONValue) async throws -> JSONValue
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

public final class HTTPBrokerTransport: BrokerTransport, @unchecked Sendable {
    private let connection: BridgeConnection
    private let session: URLSession
    public init(connection: BridgeConnection) {
        self.connection = connection
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = BridgeLimits.concurrentCalls
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func execute(tool: String, arguments: JSONValue) async throws -> JSONValue {
        let body = try JSONValue.object(["tool": .string(tool), "arguments": arguments]).encoded()
        guard body.count <= BridgeLimits.commandBody else {
            throw BridgeFailure("request_too_large", "The encoded task command exceeds 64 KiB. Shorten its title or notes before retrying.")
        }
        try Task.checkCancellation()
        var request = URLRequest(url: connection.endpoint.appendingPathComponent("v1/command"))
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization")
        request.setValue(connection.clientID, forHTTPHeaderField: "X-HeyNotch-Client")
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw uncertain(tool: tool) }
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw uncertain(tool: tool) }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw BridgeFailure("access_denied", "HeyNotch rejected this connection. Check the client's access in HeyNotch and export a new connection if needed.")
            }
            throw uncertain(tool: tool)
        }
        guard response.expectedContentLength <= BridgeLimits.brokerResponse else { throw uncertain(tool: tool) }
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < BridgeLimits.brokerResponse else { throw uncertain(tool: tool) }
                data.append(byte)
            }
        } catch let failure as BridgeFailure { throw failure }
        catch { if Task.isCancelled { throw CancellationError() }; throw uncertain(tool: tool) }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let ok = value["ok"]?.boolean,
              ok ? value["result"]?.object != nil : (value["error"]?["code"]?.string != nil && value["error"]?["message"]?.string != nil) else {
            throw uncertain(tool: tool)
        }
        return value.replacingSecret(connection.token)
    }
    private func uncertain(tool: String) -> BridgeFailure {
        if ToolCatalog.writeTools.contains(tool) {
            return BridgeFailure("write_outcome_unknown", "The bridge did not receive a complete result. The write may have completed. Query get_operation with the original operationID; do not create a new operationID to retry this change.")
        }
        return BridgeFailure("broker_unavailable", "HeyNotch did not return a complete result. Keep HeyNotch running with task automation enabled, then retry the read.")
    }
}
