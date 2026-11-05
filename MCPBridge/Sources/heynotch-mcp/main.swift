import Darwin
import Foundation
import HeyNotchMCPCore

private final class ProtocolOutput: @unchecked Sendable {
    private let lock = NSLock()
    func send(_ value: JSONValue) {
        guard var data = try? value.encoded() else { return }
        data.append(10)
        lock.lock(); defer { lock.unlock() }
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(STDOUT_FILENO, base.advanced(by: written), bytes.count - written)
                if count < 0 { if errno == EINTR { continue }; exit(0) }
                if count == 0 { exit(0) }
                written += count
            }
        }
    }
}

@main
struct HeyNotchMCPMain {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] {
            diagnostic("Usage: heynotch-mcp --connection /absolute/path/client.json\nNative stdio MCP bridge. Keep HeyNotch running with task automation enabled.")
            return
        }
        guard args.count == 2, args[0] == "--connection" else {
            diagnostic("Usage: heynotch-mcp --connection /absolute/path/client.json"); exit(64)
        }
        let connection: BridgeConnection
        do { connection = try BridgeConnection.load(path: args[1]) }
        catch let failure as BridgeFailure { diagnostic(failure.message); exit(78) }
        catch { diagnostic("The private HeyNotch connection could not be loaded."); exit(78) }
        let output = ProtocolOutput()
        let server = MCPServer(transport: HTTPBrokerTransport(connection: connection), output: { output.send($0) })
        var framer = StdioFramer()
        do {
            for try await byte in FileHandle.standardInput.bytes {
                if let line = try framer.append(byte) { await server.receive(line) }
            }
            if framer.hasPartialLine { await server.framingError() }
        } catch {
            await server.framingError()
        }
        await server.shutdown()
    }
    private static func diagnostic(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
