import AppKit
import SwiftUI

// Counter hooks are inserted into temporary copies of the two production views.
enum TimerProbe {
    static var faceAppears = 0
    static var faceDisappears = 0
    static var faceStarts = 0
    static var faceTicks = 0
    static var spectrumStarts = 0
    static var spectrumTicks = 0
    static var spectrumDeinits = 0
    static var lastFaceTicks = 0
    static var lastSpectrumTicks = 0
    static var rows: [Row] = []

    struct Row: Codable {
        let phase: String
        let seconds: Double
        let faceAppears: Int
        let faceDisappears: Int
        let faceStarts: Int
        let faceTicks: Int
        let spectrumStarts: Int
        let spectrumTicks: Int
        let spectrumDeinits: Int
    }

    static func record(_ phase: String, seconds: Double) {
        rows.append(Row(phase: phase, seconds: seconds,
                        faceAppears: faceAppears, faceDisappears: faceDisappears,
                        faceStarts: faceStarts, faceTicks: faceTicks - lastFaceTicks,
                        spectrumStarts: spectrumStarts, spectrumTicks: spectrumTicks - lastSpectrumTicks,
                        spectrumDeinits: spectrumDeinits))
        lastFaceTicks = faceTicks
        lastSpectrumTicks = spectrumTicks
    }

    struct Report: Codable {
        let phases: [Row]
        let spectrumReleased: Bool
        let panelWasVisible: Bool
    }
}

private struct ProbeViews: View {
    let mounted: Bool
    var body: some View {
        VStack {
            if mounted {
                MinimalFaceFeatures()
                AudioSpectrumView(isPlaying: .constant(true))
            } else {
                Color.clear.frame(width: 80, height: 80)
            }
        }.frame(width: 120, height: 120)
    }
}

@main private struct AnimationLifecycleProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let panel = NSPanel(contentRect: NSRect(x: -5000, y: -5000, width: 120, height: 120),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ProbeViews(mounted: true))
        panel.contentView = host
        host.layoutSubtreeIfNeeded()

        // Never order or activate the panel. Native layout is enough to exercise
        // SwiftUI appearance, disappearance and NSViewRepresentable teardown.
        Task { @MainActor in
            for (index, mounted) in [true, false, true, false].enumerated() {
                if index > 0 {
                    host.rootView = ProbeViews(mounted: mounted)
                    host.layoutSubtreeIfNeeded()
                }
                try? await Task.sleep(for: .seconds(4))
                TimerProbe.record(["mounted-1", "removed-1", "mounted-2", "removed-2"][index], seconds: 4)
            }

            var spectrum: AudioSpectrum? = AudioSpectrum()
            panel.contentView = spectrum
            spectrum?.setPlaying(true)
            try? await Task.sleep(for: .milliseconds(1200))
            TimerProbe.record("native-attached-playing", seconds: 1.2)
            spectrum?.isHidden = true
            try? await Task.sleep(for: .milliseconds(1200))
            TimerProbe.record("native-hidden", seconds: 1.2)
            spectrum?.isHidden = false
            try? await Task.sleep(for: .milliseconds(1200))
            TimerProbe.record("native-unhidden-playing", seconds: 1.2)
            spectrum?.setPlaying(false)
            try? await Task.sleep(for: .milliseconds(1200))
            TimerProbe.record("native-paused", seconds: 1.2)
            spectrum?.setPlaying(true)
            try? await Task.sleep(for: .milliseconds(1200))
            TimerProbe.record("native-resumed", seconds: 1.2)
            weak let released = spectrum
            panel.contentView = nil
            spectrum = nil
            try? await Task.sleep(for: .milliseconds(1200))
            TimerProbe.record("native-detached-released", seconds: 1.2)

            let report = TimerProbe.Report(phases: TimerProbe.rows, spectrumReleased: released == nil,
                                           panelWasVisible: panel.isVisible)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try! encoder.encode(report), as: UTF8.self))
            fflush(stdout)
            app.stop(nil)
            // Wake the run loop after stop without posting keyboard/mouse input.
            let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          subtype: 0, data1: 0, data2: 0)!
            app.postEvent(event, atStart: true)
        }
        app.run()
    }
}
