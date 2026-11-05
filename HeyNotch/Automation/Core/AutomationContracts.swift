import CryptoKit
import Foundation

struct AutomationContext {
    let clientID: String
    let allowedListIDs: Set<String>
    let canWrite: Bool
    let authorizationCheck: @MainActor () -> Bool

    init(clientID: String, allowedListIDs: Set<String>, canWrite: Bool,
         authorizationCheck: @escaping @MainActor () -> Bool = { true }) {
        self.clientID = clientID; self.allowedListIDs = allowedListIDs; self.canWrite = canWrite
        self.authorizationCheck = authorizationCheck
    }
}

struct AutomationFailure: Error {
    let code: String
    let message: String
    static let invalid = Self(code: "invalid_arguments", message: "Check the tool arguments and their supported fields.")
    static let denied = Self(code: "access_denied", message: "This connection no longer has access to this operation or list.")
    static let uncertain = Self(code: "outcome_uncertain", message: "The operation may have changed the task. Check its operation status; do not submit a new operation ID to retry it.")
}

enum AutomationJSON {
    static let maximumRequestBytes = 65_536
    static let maximumResponseBytes = 524_288
    static func encode(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func success(_ result: [String: Any]) throws -> Data {
        let data = try encode(["ok": true, "result": result])
        guard data.count <= maximumResponseBytes else {
            throw AutomationFailure(code: "response_too_large", message: "This result is too large. Request fewer tasks or a narrower search.")
        }
        return data
    }
    static func failure(_ error: Error) -> Data {
        let failure: AutomationFailure
        if let known = error as? AutomationFailure { failure = known }
        else if error is CancellationError { failure = .init(code: "cancelled", message: "The request was cancelled before a verified result was available.") }
        else if let known = error as? TaskServiceError {
            let code: String
            switch known {
            case .permission: code = "permission_required"
            case .noList: code = "list_unavailable"
            case .readOnly: code = "read_only"
            case .missing: code = "not_found"
            case .invalidDraft: code = "invalid_arguments"
            case .fetchFailed: code = "read_failed"
            case .saveFailed: code = "write_failed"
            case .duplicateUncertain: code = "outcome_uncertain"
            }
            failure = .init(code: code, message: known.localizedDescription)
        } else { failure = .init(code: "internal_error", message: "HeyNotch could not finish this request.") }
        return (try? encode(["ok": false, "error": ["code": failure.code, "message": failure.message]])) ?? Data("{\"ok\":false,\"error\":{\"code\":\"internal_error\",\"message\":\"Request failed.\"}}".utf8)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func date(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
