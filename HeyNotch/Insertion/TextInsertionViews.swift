import AppKit
import KeyboardShortcuts
import SwiftUI

struct TextInsertionSettingsSection: View {
    @ObservedObject private var insertion = TextInsertionCoordinator.shared
    @AppStorage(TextInsertionCoordinator.enabledKey) private var enabled = false
    @AppStorage(TextInsertionCoordinator.restoreKey) private var restoreClipboard = true

    var body: some View {
        Section("Text insertion preview") {
            Toggle("Enable insertion shortcut", isOn: $enabled)
                .onChange(of: enabled) { _, enabled in if !enabled { insertion.cancel() } }
            KeyboardShortcuts.Recorder("Insert test text:", name: .testTextInsertion)
                .disabled(!enabled)
            TextField("Text to try", text: $insertion.sampleText, axis: .vertical)
                .lineLimit(2...5)
                .disabled(insertion.isBusy)
            Toggle("Restore clipboard after pasting", isOn: $restoreClipboard)
            Text("Restoration waits one second. If an app pastes slowly, turn this off to leave the inserted text on the clipboard. Promised files and clipboard contents over 16 MB cannot be restored.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Try in 5 seconds") { insertion.tryAfterCountdown() }
                    .disabled(insertion.isBusy)
                Button("Allow Accessibility…") { insertion.requestAccessibility() }
            }
            Text(insertion.status)
                .font(.callout)
                .textSelection(.enabled)
                .accessibilityLabel("Insertion status: \(insertion.status)")
            HStack {
                Button("Copy text") { insertion.copyRetainedText() }
                    .disabled(insertion.retainedText.isEmpty || insertion.isBusy)
                if insertion.isBusy { Button("Cancel") { insertion.cancel() } }
            }
        }
    }
}

@MainActor
final class InsertionStatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(coordinator: TextInsertionCoordinator) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 370, height: 145),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        contentView = NSHostingView(rootView: InsertionStatusView(insertion: coordinator))
    }

    func showWithoutActivation() {
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            setFrameOrigin(NSPoint(x: screen.frame.midX - frame.width / 2,
                                   y: screen.visibleFrame.maxY - frame.height - 10))
        }
        orderFrontRegardless()
    }
}

private struct InsertionStatusView: View {
    @ObservedObject var insertion: TextInsertionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("HeyNotch text insertion", systemImage: "text.cursor")
                    .font(.headline)
                Spacer()
                if !insertion.isBusy {
                    Button { insertion.dismissStatus() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss insertion status")
                }
            }
            Text(insertion.status)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if insertion.isBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { insertion.cancel() }
                } else {
                    Button("Copy text") { insertion.copyRetainedText() }
                        .disabled(insertion.retainedText.isEmpty)
                    if insertion.needsAccessibility {
                        Button("Allow Accessibility…") { insertion.requestAccessibility() }
                    }
                }
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 370, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
