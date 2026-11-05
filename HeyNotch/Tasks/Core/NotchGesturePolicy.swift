import Foundation

/// The region where a notch gesture may start, in coordinates measured from the view's top left.
enum NotchGestureRegion: Equatable {
    case entireView
    case top(height: CGFloat)

    func contains(_ point: CGPoint, in size: CGSize) -> Bool {
        guard point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              point.x >= 0, point.x < size.width, point.y >= 0, point.y < size.height else { return false }
        switch self {
        case .entireView: return true
        case .top(let height): return height.isFinite && point.y < max(0, height)
        }
    }
}

/// A pure scroll-stream gate. Rejected starts stay rejected until the next gesture; inertia never
/// starts one. Supplying an activation threshold latches after its first crossing.
struct NotchGesturePolicy {
    enum Direction: Equatable {
        case left, right, up, down
        var isHorizontal: Bool { self == .left || self == .right }
        var sign: CGFloat { (self == .right || self == .down) ? 1 : -1 }
        func signed(deltaX: CGFloat, deltaY: CGFloat) -> CGFloat {
            (isHorizontal ? deltaX : deltaY) * sign
        }
        func signed(from translation: CGSize) -> CGFloat {
            signed(deltaX: translation.width, deltaY: translation.height)
        }
    }

    enum Phase { case began, changed, ended, cancelled, unphased }
    struct Update: Equatable {
        enum Phase { case began, changed, ended }
        let translation: CGFloat
        let phase: Phase
    }

    private enum Admission { case idle, allowed, rejected }
    private var admission: Admission = .idle
    private var accumulated: CGFloat = 0
    private var hasBegun = false
    private var activated = false

    /// Only visible gesture feedback needs an eagerly delivered inactivity end. Rejected or
    /// below-threshold wheel streams can reset lazily when the next wheel event arrives.
    var needsInactivityEnd: Bool { hasBegun }

    mutating func process(
        direction: Direction,
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: Phase,
        isMomentum: Bool = false,
        isPrecise: Bool = true,
        isEnabled: Bool,
        locationAllowed: Bool,
        threshold: CGFloat = 4,
        activationThreshold: CGFloat? = nil
    ) -> [Update] {
        if isMomentum || phase == .ended || phase == .cancelled { return finish() }

        var updates: [Update] = []
        if phase == .began {
            updates = finish()
            admission = isEnabled && locationAllowed ? .allowed : .rejected
        } else if admission == .idle {
            // Wheel mice have no phases. A phased trackpad stream must have an observed start;
            // installing/enabling a modifier midway through scrolling must not arm it.
            admission = phase == .unphased && isEnabled && locationAllowed ? .allowed : .rejected
        }

        guard admission == .allowed else { return updates }
        guard isEnabled && locationAllowed else {
            updates += finish()
            admission = .rejected
            return updates
        }
        guard !activated, deltaX.isFinite, deltaY.isFinite else { return updates }

        let along = abs(direction.isHorizontal ? deltaX : deltaY)
        let across = abs(direction.isHorizontal ? deltaY : deltaX)
        guard along >= 1.5 * across else { return updates }
        let delta = direction.signed(deltaX: deltaX, deltaY: deltaY) * (isPrecise ? 1 : 8)
        guard delta.isFinite, abs(delta) > 0.2 else { return updates }
        accumulated = delta > 0 ? accumulated + delta : 0
        guard accumulated.isFinite else {
            updates += finish()
            admission = .rejected
            return updates
        }

        let beginAt = threshold.isFinite ? max(0.2, threshold) : 4
        if !hasBegun, accumulated >= beginAt {
            hasBegun = true
            updates.append(Update(translation: accumulated, phase: .began))
        } else if hasBegun {
            updates.append(Update(translation: accumulated, phase: .changed))
        }
        if let activationThreshold, activationThreshold.isFinite,
           accumulated >= max(beginAt, activationThreshold) {
            activated = true
        }
        return updates
    }

    /// Used for explicit phase endings, wheel-mouse inactivity, and teardown. End never carries
    /// an activation distance, so a callback cannot trigger another action while resetting.
    mutating func finish() -> [Update] {
        let updates = hasBegun ? [Update(translation: 0, phase: .ended)] : []
        admission = .idle
        accumulated = 0
        hasBegun = false
        activated = false
        return updates
    }
}

/// Tracks an unphased wheel burst without allocating a timer for each event. Rejected starts
/// remain rejected until this quiet interval passes, even if the modifier becomes enabled.
struct NotchWheelInactivity {
    static let interval: TimeInterval = 0.3
    private var deadline: TimeInterval?

    /// Returns true when a previous burst has expired and its gesture policy should reset.
    mutating func recordEvent(at now: TimeInterval) -> Bool {
        let expired = deadline.map { now >= $0 } ?? false
        deadline = now + Self.interval
        return expired
    }

    func remaining(at now: TimeInterval) -> TimeInterval? {
        deadline.map { max(0, $0 - now) }
    }

    mutating func reset() { deadline = nil }
}
