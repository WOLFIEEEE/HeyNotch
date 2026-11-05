import Foundation
import Network
import XCTest

private actor AutomationHandlerGate {
    private var waiters: [CheckedContinuation<Data, Never>] = []
    private(set) var accepted = 0
    private var released = false
    func handle() async -> Data {
        accepted += 1
        if released { return Data("{\"ok\":true,\"result\":{}}".utf8) }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func releaseAll() {
        released = true
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume(returning: Data("{\"ok\":true,\"result\":{}}".utf8)) }
    }
}

@MainActor
final class AutomationTransportIntegrationTests: XCTestCase {
    func testDisconnectedRequestsKeepTheirSlotsAcrossListenerRestart() async throws {
        let gate = AutomationHandlerGate()
        let ready = expectation(description: "Loopback listener is ready")
        ready.assertForOverFulfill = false
        let server = AutomationHTTPServer(handler: { _ in await gate.handle() }, status: {
            if $0 == "Ready for connections on this Mac." { ready.fulfill() }
        })
        server.start()
        defer { server.stop(); Task { await gate.releaseAll() } }
        await fulfillment(of: [ready], timeout: 3)
        let client = UUID().uuidString, token = String(repeating: "a", count: 43)
        let wire = Data("POST /v1/command HTTP/1.1\r\nHost: 127.0.0.1:49371\r\nContent-Type: application/json\r\nContent-Length: 2\r\nAuthorization: Bearer \(token)\r\nX-HeyNotch-Client: \(client)\r\n\r\n{}".utf8)
        // Each socket closes only after the handler is demonstrably accepted.
        // Its queued command remains alive behind the gate.
        for index in 1...8 {
            let socket = NWConnection(host: "127.0.0.1", port: 49371, using: .tcp)
            socket.stateUpdateHandler = { state in
                if case .ready = state { socket.send(content: wire, completion: .contentProcessed { _ in }) }
            }
            socket.start(queue: DispatchQueue.global(qos: .utility))
            var accepted = false
            for _ in 0..<100 {
                if await gate.accepted == index { accepted = true; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            socket.stateUpdateHandler = nil; socket.cancel()
            XCTAssertTrue(accepted, "Handler \(index) must be accepted before closing its socket")
            guard accepted else { return }
        }
        // Stopping the listener clears its sockets, just as a socket deadline
        // does, but must not erase the eight still-running handler slots.
        server.stop(); server.start()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]; configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:49371/v1/command")!)
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(client, forHTTPHeaderField: "X-HeyNotch-Client")
        var responseData: Data?
        for _ in 0..<20 {
            if let (data, _) = try? await session.data(for: request) { responseData = data; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let data = try XCTUnwrap(responseData, "Listener must restart without accepting another handler")
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((result["error"] as? [String: Any])?["code"] as? String, "busy")
        let count = await gate.accepted
        XCTAssertEqual(count, 8)
        await gate.releaseAll()
    }

    private final class Repository: TaskRepository {
        var tasks: [ReminderTask] = []
        var saves = 0
        func requestAccess() async throws { XCTFail("Automation must never request OS permissions") }
        func lists() throws -> [TaskList] { [TaskList(id: "fixture-list", title: "Fixture", account: "Test", isLocal: true, writable: true)] }
        func fetch() async throws -> [ReminderTask] { tasks }
        func save(_ draft: TaskDraft) async throws -> String {
            saves += 1
            let id = draft.reminderID ?? UUID().uuidString
            let old = tasks.first(where: { $0.id == id })
            let value = ReminderTask(id: id, title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines), notes: draft.notes,
                                     due: draft.due, completed: old?.completed ?? false, listID: draft.listID,
                                     alarms: old?.alarms ?? [], recurring: false)
            tasks.removeAll { $0.id == id }; tasks.append(value)
            return id
        }
        func complete(_ id: String, completed: Bool) throws {
            guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw TaskServiceError.missing }
            tasks[index].completed = completed
        }
        func delete(_ id: String) throws { XCTFail("No deletion tool is exposed") }
    }

    func testRealLoopbackTransportAuthenticatesCreatesAndReplays() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HeyNotch-HTTP-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = Repository()
        let defaults = UserDefaults(suiteName: "HeyNotch.HTTP." + UUID().uuidString)!
        let board = TaskBoardStore(repository: repository, defaults: defaults)
        board.makeDraft("Keep this unsaved draft")
        let draft = board.draft
        let engine = AutomationTaskEngine(board: board, journalURL: directory.appendingPathComponent("journal.json"))
        let client = UUID().uuidString, token = String(repeating: "a", count: 43)
        let server = AutomationHTTPServer(handler: { request in
            guard request.clientID == client, request.token == token else {
                return AutomationHTTPServer.error("unauthorized", "Test connection rejected")
            }
            return await engine.execute(request.body, context: AutomationContext(clientID: client, allowedListIDs: ["fixture-list"], canWrite: true))
        }, status: { _ in })
        server.start(); defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        func call(_ tool: String, _ arguments: [String: Any], secret: String? = nil) async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:49371/v1/command")!)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["tool": tool, "arguments": arguments])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + (secret ?? token), forHTTPHeaderField: "Authorization")
            request.setValue(client, forHTTPHeaderField: "X-HeyNotch-Client")
            let (data, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        // Wait for the asynchronous listener to bind, without blocking MainActor.
        var ready = false
        for _ in 0..<30 {
            if let result = try? await call("get_context", [:]), result["ok"] as? Bool == true { ready = true; break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(ready)
        guard ready else { return }
        let denied = try await call("list_task_lists", [:], secret: String(repeating: "b", count: 43))
        XCTAssertEqual((denied["error"] as? [String: Any])?["code"] as? String, "unauthorized")
        let operation = UUID().uuidString
        let arguments: [String: Any] = ["operationID": operation, "listID": "fixture-list", "title": "MCP integration fixture", "notes": "Only in-memory test data"]
        let first = try await call("create_task", arguments)
        XCTAssertEqual(first["ok"] as? Bool, true, "\(first)")
        let second = try await call("create_task", arguments)
        XCTAssertEqual(try AutomationJSON.encode(first), try AutomationJSON.encode(second))
        XCTAssertEqual(repository.saves, 1)
        XCTAssertEqual(repository.tasks.count, 1)
        XCTAssertEqual(board.draft, draft)
        let found = try await call("find_tasks", ["query": "MCP integration"])
        XCTAssertEqual(found["ok"] as? Bool, true)
        let conflict = try await call("create_task", ["operationID": operation, "listID": "fixture-list", "title": "Different"])
        XCTAssertEqual(conflict["ok"] as? Bool, false)
        XCTAssertEqual(repository.saves, 1)
        try await verifyStdioBridge(directory: directory, client: client, token: token)
        XCTAssertEqual(repository.tasks.count, 2)
        XCTAssertTrue(repository.tasks.contains(where: { $0.title == "Stdio verified edit" && $0.completed }))
    }

    private func verifyStdioBridge(directory: URL, client: String, token: String) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let bridge = root.appendingPathComponent("MCPBridge/.build/debug/heynotch-mcp")
        guard FileManager.default.isExecutableFile(atPath: bridge.path) else {
            throw XCTSkip("Build MCPBridge with swift build --package-path MCPBridge to run the actual stdio connector test.")
        }
        let credential = directory.appendingPathComponent("connection.json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "endpoint": "http://127.0.0.1:49371", "clientID": client, "token": token]).write(to: credential)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credential.path)
        let script = #"""
import json, subprocess, sys, uuid, select
p = subprocess.Popen([sys.argv[1], '--connection', sys.argv[2]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
sequence = 0
def send(value):
    p.stdin.write(json.dumps(value) + '\n'); p.stdin.flush()
def call(method, params):
    global sequence
    sequence += 1
    send({'jsonrpc':'2.0','id':sequence,'method':method,'params':params})
    if not select.select([p.stdout], [], [], 15)[0]: raise AssertionError('MCP response timed out')
    reply=json.loads(p.stdout.readline())
    assert reply.get('id') == sequence and 'result' in reply, reply
    return reply['result']
def tool(name, args):
    value=call('tools/call', {'name':name,'arguments':args})
    assert not value.get('isError'), value
    result=value.get('structuredContent') or json.loads(value['content'][0]['text'])
    assert result.get('ok') is True, result
    return result['result']
def op(): return str(uuid.uuid4())
try:
    call('initialize',{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'HeyNotch integration fixture','version':'1'}})
    send({'jsonrpc':'2.0','method':'notifications/initialized'})
    assert len(call('tools/list',{})['tools']) == 9
    tool('get_context',{})
    assert tool('list_task_lists',{})['lists'][0]['id']=='fixture-list'
    operation=op()
    args={'operationID':operation,'listID':'fixture-list','title':'Stdio verified task'}
    first=tool('create_task',args)
    assert tool('create_task',args)==first
    task=tool('get_task',{'taskID':first['task']['id']})['task']
    task=tool('update_task',{'operationID':op(),'taskID':task['id'],'expectedRevision':task['revision'],'title':'Stdio verified edit'})['task']
    task=tool('move_task',{'operationID':op(),'taskID':task['id'],'expectedRevision':task['revision'],'column':'doing'})['task']
    assert task['column']=='doing'
    task=tool('set_task_completed',{'operationID':op(),'taskID':task['id'],'expectedRevision':task['revision'],'completed':True})['task']
    assert task['completed'] is True and task['column']=='done'
    assert tool('get_operation',{'operationID':operation})['status']=='succeeded'
    assert len(tool('find_tasks',{'query':'Stdio verified edit'})['tasks'])==1
    print('Passed actual MCP stdio -> loopback -> task engine -> readback across all nine tools.')
finally:
    p.stdin.close()
    try: p.wait(timeout=3)
    except subprocess.TimeoutExpired: p.kill(); p.wait()
"""#
        let result: (Int32, String) = try await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", script, bridge.path, credential.path]
            process.standardOutput = output; process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        XCTAssertEqual(result.0, 0, result.1)
    }
}
