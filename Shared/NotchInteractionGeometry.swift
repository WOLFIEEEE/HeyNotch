import Foundation

/// Visible notch geometry in AppKit screen coordinates. The transparent hosting
/// panel is deliberately larger and must never be used as a hover target.
enum NotchInteractionGeometry {
    static func screenRect(screenFrame: CGRect, size: CGSize) -> CGRect {
        guard screenFrame.origin.x.isFinite, screenFrame.origin.y.isFinite,
              screenFrame.width.isFinite, screenFrame.height.isFinite,
              screenFrame.width > 0, screenFrame.height > 0,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return .zero }
        let width = min(size.width, screenFrame.width)
        let height = min(size.height, screenFrame.height)
        return CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height,
                      width: width, height: height)
    }

    static func contains(point: CGPoint, screenFrame: CGRect, size: CGSize) -> Bool {
        let rect = screenRect(screenFrame: screenFrame, size: size)
        guard point.x.isFinite, point.y.isFinite, !rect.isEmpty else { return false }
        // Include the physical top edge, where the pointer can be pinned.
        return point.x >= rect.minX && point.x <= rect.maxX
            && point.y >= rect.minY && point.y <= rect.maxY
    }
}
