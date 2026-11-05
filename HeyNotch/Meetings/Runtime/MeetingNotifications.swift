import Foundation
import UserNotifications

@MainActor
final class MeetingNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MeetingNotifications()
    private let center = UNUserNotificationCenter.current()
    private let identifier = "heynotch.meeting-suggestion"
    private let launchedAt = Date()
    private lazy var service = MeetingNotificationService(transport: SystemMeetingNotificationTransport(center: center))
    func configure() {
        center.delegate = self
        Task {
            let delivered = await center.deliveredNotifications()
            let pending = await center.pendingNotificationRequests()
            center.removeDeliveredNotifications(withIdentifiers: delivered.filter { $0.date < launchedAt }.map { $0.request.identifier }.filter { $0.hasPrefix(MeetingNotificationService.prefix) })
            center.removePendingNotificationRequests(withIdentifiers: pending.filter {
                ($0.content.userInfo["createdAt"] as? Double ?? 0) < launchedAt.timeIntervalSince1970
            }.map(\.identifier).filter { $0.hasPrefix(MeetingNotificationService.prefix) })
        }
        let start = UNNotificationAction(identifier: "transcribe", title: "Transcribe…", options: [.foreground])
        let snooze = UNNotificationAction(identifier: "snooze", title: "Snooze 1 hour", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: "MEETING", actions: [start, snooze], intentIdentifiers: [], options: [.customDismissAction])])
    }
    func requestPermission() async -> (allowed: Bool, message: String) {
        do {
            let allowed = try await center.requestAuthorization(options: [.alert])
            return (allowed, allowed ? "Meeting reminders will use macOS notifications and follow your Focus settings." : "Notifications are disabled. The in-app reminder is still available.")
        } catch { return (false, "Notifications could not be enabled. The in-app reminder is still available.") }
    }
    func deliver(_ activity: MeetingActivity, token: UUID) async -> Bool {
        await service.deliver(activity, token: token, enabled: UserDefaults.standard.bool(forKey: "meetings.systemNotifications"))
    }
    func clear() { service.clear() }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let token = (response.notification.request.content.userInfo["token"] as? String).flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier == UNNotificationDismissActionIdentifier ? "dismiss" : response.actionIdentifier
        Task { @MainActor in
            if let token { MeetingCoordinator.shared.respondToNotification(action, token: token) }
            completionHandler()
        }
    }
}

@MainActor
private final class SystemMeetingNotificationTransport: MeetingNotificationTransport {
    let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter) { self.center = center }
    func canShowAlerts() async -> Bool {
        let settings = await center.notificationSettings()
        return (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional) && settings.alertSetting == .enabled
    }
    func add(identifier: String, activity: MeetingActivity, token: UUID) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Transcribe this call?"
        content.body = activity.message + " Recording starts only after you choose Start."
        content.categoryIdentifier = "MEETING"; content.userInfo = ["token": token.uuidString, "createdAt": Date().timeIntervalSince1970]
        content.threadIdentifier = "heynotch.meeting-suggestion"
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
    func remove(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
