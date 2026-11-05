import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), integer(Int64), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Int64.self) { self = .integer(v) }
        else if let v = try? value.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .integer(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var integer: Int64? { if case .integer(let v) = self { return v }; return nil }
    public var boolean: Bool? { if case .bool(let v) = self { return v }; return nil }
    public subscript(_ key: String) -> JSONValue? { object?[key] }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    public func replacingSecret(_ secret: String) -> JSONValue {
        switch self {
        case .string(let value): return .string(value.replacingOccurrences(of: secret, with: "[redacted]"))
        case .array(let values): return .array(values.map { $0.replacingSecret(secret) })
        case .object(let values): return .object(Dictionary(values.map { ($0.key.replacingOccurrences(of: secret, with: "[redacted]"), $0.value.replacingSecret(secret)) }, uniquingKeysWith: { _, last in last }))
        default: return self
        }
    }
}

public enum BridgeLimits {
    public static let inputLine = 262_144
    public static let commandBody = 65_536
    public static let brokerResponse = 2_097_152
    public static let credentialFile = 16_384
    public static let concurrentCalls = 8
}

public struct BridgeFailure: Error, Sendable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}
