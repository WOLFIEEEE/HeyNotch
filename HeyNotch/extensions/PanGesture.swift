//
//  PanGesture.swift
//  HeyNotch
//
//  Created by Richard Kunkli on 21/08/2024.
//

import AppKit
import SwiftUI

typealias PanDirection = NotchGesturePolicy.Direction

extension View {
    /// Keep an open-notch close gesture on the header, or restrict it to `.top(height:)`.
    /// Set `activationThreshold` to the caller's action distance to allow one action per swipe.
    func panGesture(
        direction: PanDirection,
        threshold: CGFloat = 4,
        isEnabled: Bool = true,
        allowedRegion: NotchGestureRegion = .entireView,
        activationThreshold: CGFloat? = nil,
        action: @escaping (CGFloat, NSEvent.Phase) -> Void
    ) -> some View {
        modifier(PanGestureModifier(direction: direction, threshold: threshold,
                                    isEnabled: isEnabled, allowedRegion: allowedRegion,
                                    activationThreshold: activationThreshold, action: action))
    }
}

private struct PanGestureModifier: ViewModifier {
    let direction: PanDirection
    let threshold: CGFloat
    let isEnabled: Bool
    let allowedRegion: NotchGestureRegion
    let activationThreshold: CGFloat?
    let action: (CGFloat, NSEvent.Phase) -> Void
    @State private var dragPolicy = NotchGesturePolicy()
    @State private var previousDragTranslation: CGSize?

    func body(content: Content) -> some View {
        dragContent(content)
            // The passive monitor remains installed while disabled, so enabling it in the
            // middle of a scroll cannot reinterpret the remainder as a new gesture.
            .background(ScrollMonitor(direction: direction, threshold: threshold,
                                      isEnabled: isEnabled, allowedRegion: allowedRegion,
                                      activationThreshold: activationThreshold, action: action))
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { finishDrag() }
            }
    }

    @ViewBuilder private func dragContent(_ content: Content) -> some View {
        if isEnabled {
            content.simultaneousGesture(
                DragGesture(minimumDistance: max(4, threshold))
                    .onChanged { value in
                        let previous = previousDragTranslation
                        previousDragTranslation = value.translation
                        let startAllowed: Bool = {
                            switch allowedRegion {
                            case .entireView: return true
                            case .top(let height):
                                return height.isFinite && value.startLocation.y >= 0 && value.startLocation.y < height
                            }
                        }()
                        let updates = dragPolicy.process(
                            direction: direction,
                            deltaX: value.translation.width - (previous?.width ?? 0),
                            deltaY: value.translation.height - (previous?.height ?? 0),
                            phase: previous == nil ? .began : .changed,
                            isEnabled: isEnabled, locationAllowed: startAllowed,
                            threshold: threshold, activationThreshold: activationThreshold)
                        send(updates, to: action)
                    }
                    .onEnded { _ in finishDrag() }
            )
        } else {
            // Do not install a disabled DragGesture over task cards, text, or native scrolling.
            content
        }
    }

    private func finishDrag() {
        previousDragTranslation = nil
        send(dragPolicy.finish(), to: action)
    }
}

private func send(_ updates: [NotchGesturePolicy.Update], to action: (CGFloat, NSEvent.Phase) -> Void) {
    for update in updates {
        let phase: NSEvent.Phase
        switch update.phase {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        }
        action(update.translation, phase)
    }
}

private struct ScrollMonitor: NSViewRepresentable {
    let direction: PanDirection
    let threshold: CGFloat
    let isEnabled: Bool
    let allowedRegion: NotchGestureRegion
    let activationThreshold: CGFloat?
    let action: (CGFloat, NSEvent.Phase) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.update(from: self)
        context.coordinator.installMonitor(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(from: self)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator { Coordinator(configuration: self) }

    @MainActor final class Coordinator: NSObject {
        private var configuration: ScrollMonitor
        private var monitor: Any?
        private var policy = NotchGesturePolicy()
        private var endTask: Task<Void, Never>?
        private var wheelInactivity = NotchWheelInactivity()

        init(configuration: ScrollMonitor) { self.configuration = configuration }

        func update(from configuration: ScrollMonitor) {
            // SwiftUI reuses representables: actions, regions and enabled state must not be
            // captured once at installation, especially when the notch opens or changes tabs.
            self.configuration = configuration
        }

        func installMonitor(on view: NSView) {
            removeMonitor()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self, weak view] event in
                guard let self, let view, let window = view.window, event.window === window else { return event }
                self.handleScroll(event, in: view)
                // Never consume the event: ScrollView and other native controls must receive it.
                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            cancelEndTimeout()
            wheelInactivity.reset()
            _ = policy.finish()
        }

        private func handleScroll(_ event: NSEvent, in view: NSView) {
            let phase: NotchGesturePolicy.Phase
            if event.phase.contains(.cancelled) { phase = .cancelled }
            else if event.phase.contains(.ended) { phase = .ended }
            else if event.phase.contains(.began) || event.phase.contains(.mayBegin) { phase = .began }
            else if event.phase.contains(.changed) || event.phase.contains(.stationary) { phase = .changed }
            else { phase = .unphased }

            let isUnphasedWheel = event.phase.isEmpty && event.momentumPhase.isEmpty
            if isUnphasedWheel {
                // A rejected start still owns its burst. Reset only after actual inactivity,
                // rather than rearming when the pointer enters the header or state changes.
                if wheelInactivity.recordEvent(at: ProcessInfo.processInfo.systemUptime) {
                    send(policy.finish(), to: configuration.action)
                }
            } else {
                cancelEndTimeout()
                wheelInactivity.reset()
            }

            let point = view.convert(event.locationInWindow, from: nil)
            let topLeftPoint = CGPoint(x: point.x - view.bounds.minX,
                                       y: view.isFlipped ? point.y - view.bounds.minY : view.bounds.maxY - point.y)
            let updates = policy.process(
                direction: configuration.direction,
                deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                phase: phase, isMomentum: !event.momentumPhase.isEmpty,
                isPrecise: event.hasPreciseScrollingDeltas,
                isEnabled: configuration.isEnabled,
                locationAllowed: configuration.allowedRegion.contains(topLeftPoint, in: view.bounds.size),
                threshold: configuration.threshold,
                activationThreshold: configuration.activationThreshold)
            send(updates, to: configuration.action)

            guard isUnphasedWheel else { return }
            guard policy.needsInactivityEnd else {
                cancelEndTimeout()
                return
            }
            scheduleEndTimeoutIfNeeded()
        }

        private func cancelEndTimeout() {
            endTask?.cancel()
            endTask = nil
        }

        private func scheduleEndTimeoutIfNeeded() {
            guard endTask == nil else { return }
            // One task follows the moving deadline for an accepted wheel burst. Rejected
            // body scrolling and disabled modifiers need no task or end callback.
            endTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let delay = self?.wheelInactivity.remaining(at: ProcessInfo.processInfo.systemUptime) else { return }
                    if delay > 0 {
                        do { try await Task.sleep(for: .seconds(delay)) }
                        catch { return }
                        continue
                    }
                    guard let self else { return }
                    send(self.policy.finish(), to: self.configuration.action)
                    self.wheelInactivity.reset()
                    self.endTask = nil
                    return
                }
            }
        }
    }
}
