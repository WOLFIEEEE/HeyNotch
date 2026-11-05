import Foundation

@MainActor
final class TextInsertionClient {
    private struct Pending {
        let operationID: UUID
        let failureStatus: InsertionStatus
        let continuation: CheckedContinuation<InsertionResponse, Never>
        let timeout: Task<Void, Never>
    }
    private var connection: NSXPCConnection?
    private var connectionID: UUID?
    private var pending: [UUID: Pending] = [:]

    func capture(_ request: CaptureInsertionRequest) async -> InsertionResponse {
        await send(request, operationID: request.operationID, failureStatus: .helperUnavailable) { proxy, data, reply in
            proxy.captureInsertionTarget(data, with: reply)
        }
    }

    func insert(_ request: TextInsertionRequest) async -> InsertionResponse {
        await send(request, operationID: request.operationID, failureStatus: .outcomeUnknown) { proxy, data, reply in
            proxy.performTextInsertion(data, with: reply)
        }
    }

    func cancel(_ operationID: UUID) {
        (connection?.remoteObjectProxyWithErrorHandler { _ in } as? HeyNotchXPCHelperProtocol)?
            .cancelTextInsertion(operationID.uuidString)
    }

    func disconnect() {
        let previous = connection
        connection = nil
        connectionID = nil
        for id in Array(pending.keys) { fail(id) }
        previous?.invalidate()
    }

    private func connect() -> NSXPCConnection? {
        if let connection { return connection }
        let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/HeyNotchXPCHelper.xpc")
        guard let requirement = XPCPeerTrust.requirement(for: helperURL, identifier: XPCPeerTrust.helperIdentifier) else { return nil }
        let id = UUID()
        let newConnection = NSXPCConnection(serviceName: XPCPeerTrust.helperIdentifier)
        newConnection.remoteObjectInterface = NSXPCInterface(with: HeyNotchXPCHelperProtocol.self)
        newConnection.setCodeSigningRequirement(requirement)
        let ended: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard self?.connectionID == id else { return }
                self?.disconnect()
            }
        }
        newConnection.interruptionHandler = ended
        newConnection.invalidationHandler = ended
        connection = newConnection
        connectionID = id
        newConnection.resume()
        return newConnection
    }

    private func send<Request: Encodable>(_ request: Request, operationID: UUID, failureStatus: InsertionStatus,
                                          invoke: (HeyNotchXPCHelperProtocol, Data, @escaping (Data) -> Void) -> Void) async -> InsertionResponse {
        guard let data = try? JSONEncoder().encode(request), let connection = connect() else {
            return InsertionResponse(operationID: operationID, status: .helperUnavailable)
        }
        let callID = UUID()
        return await withCheckedContinuation { continuation in
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
                self?.cancel(operationID)
                self?.fail(callID)
            }
            pending[callID] = Pending(operationID: operationID, failureStatus: failureStatus,
                                      continuation: continuation, timeout: timeout)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                Task { @MainActor in self?.fail(callID) }
            }) as? HeyNotchXPCHelperProtocol else {
                fail(callID)
                return
            }
            invoke(proxy, data) { [weak self] data in
                Task { @MainActor in
                    guard let result = try? JSONDecoder().decode(InsertionResponse.self, from: data),
                          result.operationID == operationID else { self?.fail(callID); return }
                    self?.finish(callID, result: result)
                }
            }
        }
    }

    private func fail(_ id: UUID) {
        guard let call = pending[id] else { return }
        finish(id, result: InsertionResponse(operationID: call.operationID, status: call.failureStatus))
    }

    private func finish(_ id: UUID, result: InsertionResponse) {
        guard let call = pending.removeValue(forKey: id) else { return }
        call.timeout.cancel()
        call.continuation.resume(returning: result)
    }
}
