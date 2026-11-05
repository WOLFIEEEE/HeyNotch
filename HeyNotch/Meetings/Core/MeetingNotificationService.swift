import Foundation

@MainActor
protocol MeetingNotificationTransport {
    func canShowAlerts() async -> Bool
    func add(identifier: String, activity: MeetingActivity, token: UUID) async throws
    func remove(identifiers: [String])
}

/// An accepted OS request is not proof a banner was shown: Focus can suppress
/// presentation. Cancellation removes only this request, never a newer one.
@MainActor
final class MeetingNotificationService {
    static let prefix = "heynotch.meeting-suggestion."
    private let transport: any MeetingNotificationTransport
    private var current: UUID?
    private var identifiers: Set<String> = []
    init(transport: any MeetingNotificationTransport) { self.transport = transport }

    func deliver(_ activity: MeetingActivity, token: UUID, enabled: Bool) async -> Bool {
        clear()
        guard enabled else { return false }
        current = token
        let allowed = await transport.canShowAlerts()
        guard current == token, allowed else { return false }
        let id = Self.prefix + token.uuidString
        identifiers.insert(id)
        do {
            try await transport.add(identifier: id, activity: activity, token: token)
            guard current == token else { transport.remove(identifiers: [id]); return false }
            return true
        } catch {
            transport.remove(identifiers: [id]); identifiers.remove(id)
            return false
        }
    }
    func clear() {
        current = nil
        if !identifiers.isEmpty { transport.remove(identifiers: Array(identifiers)) }
        identifiers = []
    }
}
