//
//  DragDetector.swift
//  HeyNotch
//
//  Created by Alexander on 2025-11-20.
//

import Cocoa

final class DragDetector {
    typealias EntryCallback = (_ token: UUID) -> Void
    var onDragEntersNotchRegion: EntryCallback?
    var onDragExitsNotchRegion: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var policy = NotchDragPolicy()
    private let notchRegion: CGRect
    private let dragPasteboard = NSPasteboard(name: .drag)

    init(notchRegion: CGRect) {
        self.notchRegion = notchRegion
    }

    private var content: NotchDragPolicy.Content {
        let types = dragPasteboard.types ?? []
        let validTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string]
        return .init(changeCount: dragPasteboard.changeCount,
                     hasSupportedType: types.contains(where: validTypes.contains),
                     isTaskMove: types.contains(NSPasteboard.PasteboardType("com.wolfieeee.heynotch.task-move")))
    }

    /// Recheck at execution time: entering the region may enqueue work which
    /// runs after the user has moved away, released the drag, or changed content.
    func isCurrentEntry(_ token: UUID) -> Bool {
        policy.canDeliver(token, content: content,
                          primaryButtonDown: NSEvent.pressedMouseButtons & 1 != 0,
                          point: NSEvent.mouseLocation, region: notchRegion)
    }

    func startMonitoring() {
        stopMonitoring()
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            self?.handle(event)
        }
        // Global monitors exclude this app. Observe local events too so a drop
        // on our own panel cannot leave the preceding external drag latched.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if policy.end() == .exited { onDragExitsNotchRegion?() }
            policy.mouseDown(changeCount: dragPasteboard.changeCount)
        case .leftMouseDragged:
            let transition = policy.update(content: content,
                                           primaryButtonDown: NSEvent.pressedMouseButtons & 1 != 0,
                                           point: NSEvent.mouseLocation, region: notchRegion)
            deliver(transition)
        case .leftMouseUp:
            deliver(policy.end())
        default:
            break
        }
    }

    private func deliver(_ transition: NotchDragPolicy.Transition?) {
        switch transition {
        case .entered(let token): onDragEntersNotchRegion?(token)
        case .exited: onDragExitsNotchRegion?()
        case nil: break
        }
    }

    func stopMonitoring() {
        [globalMonitor, localMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        globalMonitor = nil
        localMonitor = nil
        _ = policy.end()
    }

    deinit { stopMonitoring() }
}
