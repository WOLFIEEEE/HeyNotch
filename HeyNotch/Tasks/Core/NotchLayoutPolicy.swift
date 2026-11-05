import Foundation

public enum NotchViews: String, Codable, CaseIterable, Sendable {
    case home, shelf, tasks
}

enum NotchLandingPage: String, CaseIterable, Identifiable {
    case tasks, home, shelf, lastUsed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tasks: return "Tasks"
        case .home: return "Music & Calendar"
        case .shelf: return "Shelf"
        case .lastUsed: return "Last used page"
        }
    }
    func resolve(lastUsed: NotchViews, shelfEnabled: Bool) -> NotchViews {
        let proposed: NotchViews
        switch self {
        case .tasks: proposed = .tasks
        case .home: proposed = .home
        case .shelf: proposed = .shelf
        case .lastUsed: proposed = lastUsed
        }
        return proposed == .shelf && !shelfEnabled ? .tasks : proposed
    }
}

/// Size is constrained by the display, not the old 190-point music panel.
/// The board scrolls once it reaches its user-selected height ceiling.
enum NotchLayoutPolicy {
    static func openSize(page: NotchViews, tallestColumnCount: Int, screenWidth: Double,
                         availableHeight: Double, maximumTaskHeight: Double = 500) -> CGSize {
        let widthLimit = screenWidth.isFinite ? max(1, screenWidth - 32) : 800
        let heightLimit = availableHeight.isFinite ? max(1, availableHeight - 24) : 500
        guard page == .tasks else {
            return CGSize(width: min(640, widthLimit), height: min(190, heightLimit))
        }
        let ceiling = maximumTaskHeight.isFinite ? min(600, max(320, maximumTaskHeight)) : 500
        let rows = Double(min(5, max(0, tallestColumnCount)))
        let ideal = max(290, 210 + rows * 78)
        return CGSize(width: min(800, widthLimit), height: min(ideal, ceiling, heightLimit))
    }
}
