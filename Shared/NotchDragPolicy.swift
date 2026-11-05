import Foundation

/// Keeps a drag entry tied to the current mouse gesture and drag pasteboard.
/// A queued UI callback must validate its entry again before opening the notch.
struct NotchDragPolicy {
    struct Content {
        let changeCount: Int
        let hasSupportedType: Bool
        let isTaskMove: Bool

        var isSupported: Bool { hasSupportedType && !isTaskMove }
    }

    enum Transition: Equatable {
        case entered(UUID)
        case exited
    }

    private var mouseDownChangeCount: Int?
    private var entryChangeCount: Int?
    private var entry: UUID?

    static func region(screenFrame: CGRect, closedSize: CGSize, expansion: CGFloat = 24) -> CGRect {
        let closed = NotchInteractionGeometry.screenRect(screenFrame: screenFrame, size: closedSize)
        guard !closed.isEmpty, !closed.isNull, expansion.isFinite, expansion >= 0 else { return .null }
        // AppKit screen and mouse coordinates share a bottom-left origin.
        // Expand sideways and down, never into another display above this one.
        return CGRect(x: closed.minX - expansion, y: closed.minY - expansion,
                      width: closed.width + 2 * expansion, height: closed.height + expansion)
            .intersection(screenFrame)
    }

    mutating func mouseDown(changeCount: Int) {
        _ = end()
        mouseDownChangeCount = changeCount
    }

    mutating func update(content: Content, primaryButtonDown: Bool,
                         point: CGPoint, region: CGRect) -> Transition? {
        guard primaryButtonDown else { return end() }
        guard let baseline = mouseDownChangeCount, content.changeCount != baseline,
              content.isSupported, Self.contains(point, in: region) else { return leave() }
        guard entry == nil || entryChangeCount != content.changeCount else { return nil }
        let token = UUID()
        entry = token
        entryChangeCount = content.changeCount
        return .entered(token)
    }

    func canDeliver(_ token: UUID, content: Content, primaryButtonDown: Bool,
                    point: CGPoint, region: CGRect) -> Bool {
        entry == token && primaryButtonDown && content.isSupported
            && entryChangeCount == content.changeCount
            && mouseDownChangeCount != nil && mouseDownChangeCount != content.changeCount
            && Self.contains(point, in: region)
    }

    mutating func end() -> Transition? {
        mouseDownChangeCount = nil
        return leave()
    }

    private mutating func leave() -> Transition? {
        let wasInside = entry != nil
        entry = nil
        entryChangeCount = nil
        return wasInside ? .exited : nil
    }

    static func contains(_ point: CGPoint, in region: CGRect) -> Bool {
        point.x.isFinite && point.y.isFinite && !region.isNull && !region.isInfinite
            && !region.isEmpty && point.x >= region.minX && point.x <= region.maxX
            && point.y >= region.minY && point.y <= region.maxY
    }
}
