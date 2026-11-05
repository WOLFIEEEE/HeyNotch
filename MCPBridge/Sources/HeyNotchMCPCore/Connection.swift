import Darwin
import Foundation

public struct BridgeConnection: Sendable {
    public let endpoint: URL
    public let clientID: String
    let token: String

    public static func load(path: String) throws -> BridgeConnection {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw invalidFile() }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw invalidFile() }
        defer { close(fd) }
        var initial = stat()
        guard fstat(fd, &initial) == 0, safe(initial) else { throw invalidFile() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw invalidFile() }
            if count == 0 { break }
            guard data.count + count <= BridgeLimits.credentialFile else { throw invalidFile() }
            data.append(contentsOf: buffer.prefix(count))
        }
        var final = stat()
        guard fstat(fd, &final) == 0, safe(final), initial.st_dev == final.st_dev,
              initial.st_ino == final.st_ino, initial.st_size == final.st_size,
              data.count == initial.st_size,
              initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
              initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec else { throw invalidFile() }
        return try decode(data)
    }

    static func safe(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFREG && value.st_uid == geteuid()
            && (value.st_mode & 0o7777) == 0o600 && value.st_nlink == 1
            && value.st_size > 0 && value.st_size <= BridgeLimits.credentialFile
    }
    static func invalidFile() -> BridgeFailure {
        BridgeFailure("connection_file", "Use an absolute path to a nonsymlink, single-link regular connection file owned by this user with permissions 0600 and size below 16 KiB.")
    }
    static func decode(_ data: Data) throws -> BridgeConnection {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), let fields = value.object,
              Set(fields.keys) == ["version", "endpoint", "clientID", "token"],
              fields["version"] == .integer(1), let raw = fields["endpoint"]?.string,
              raw.hasPrefix("http://127.0.0.1:"),
              let clientID = fields["clientID"]?.string, UUID(uuidString: clientID) != nil,
              let token = fields["token"]?.string, (32...128).contains(token.utf8.count),
              token.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw BridgeFailure("connection_format", "The connection file must contain version 1, a loopback endpoint, a UUID clientID and a valid private token. Export a new connection from HeyNotch.")
        }
        let portText = String(raw.dropFirst("http://127.0.0.1:".count))
        guard let port = Int(portText), (1...65535).contains(port), String(port) == portText,
              let endpoint = URL(string: raw), endpoint.host == "127.0.0.1", endpoint.port == port,
              endpoint.path.isEmpty, endpoint.query == nil, endpoint.fragment == nil,
              endpoint.user == nil, endpoint.password == nil else {
            throw BridgeFailure("connection_endpoint", "The connection endpoint must be exactly http://127.0.0.1:<port>, with no path, credentials, query, or fragment.")
        }
        return BridgeConnection(endpoint: endpoint, clientID: clientID, token: token)
    }
}
