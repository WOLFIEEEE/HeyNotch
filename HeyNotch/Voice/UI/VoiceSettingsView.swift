import AVFoundation
import KeyboardShortcuts
import SwiftUI
import WhisperKit

struct VoiceSettingsView: View {
    @ObservedObject private var speech = SpeechController.shared
    @ObservedObject private var voice = VoiceCoordinator.shared
    @AppStorage("voice.enabled") private var enabled = false
    @AppStorage("voice.model") private var model = "turbo"
    @AppStorage("voice.microphone") private var microphone = ""
    @AppStorage("voice.language") private var language = ""
    @AppStorage("voice.idleUnloadMinutes") private var idleMinutes = 5
    @AppStorage(TextInsertionCoordinator.restoreKey) private var restoreClipboard = true
    @State private var microphones: [MicrophoneDevice] = []
    @State private var microphoneStatus = ""

    var body: some View {
        Form {
            Section {
                Toggle("Enable voice input", isOn: $enabled)
                    .onChange(of: enabled) { _, value in if !value { voice.cancel() } }
                Text("Speech recognition runs on this Mac. Audio is kept in memory only while recording and transcribing. AI cleanup is optional in Processing settings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Microphone") {
                Picker("Input", selection: $microphone) {
                    Text("System default").tag("")
                    ForEach(microphones) { Text($0.name).tag($0.id) }
                    if !microphone.isEmpty && !microphones.contains(where: { $0.id == microphone }) { Text("Saved microphone · unavailable").tag(microphone) }
                }
                .disabled(voice.phase.isBusy || speech.isInUse)
                HStack {
                    Button("Refresh inputs") { microphones = MicrophoneDevice.available() }
                    Button("Allow microphone") {
                        Task { microphoneStatus = await voice.recorder.requestPermission() ? "Microphone access is allowed." : VoiceError.microphoneDenied.localizedDescription }
                    }
                    Button("Microphone settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
                    }
                }
                if !microphoneStatus.isEmpty { Text(microphoneStatus).font(.caption) }
            }
            Section("Speech recognition") {
                Picker("Model", selection: $model) {
                    ForEach(speech.models) { model in
                        Text("\(model.name) · \(ByteCountFormatter.string(fromByteCount: model.byteCount, countStyle: .file))").tag(model.id)
                    }
                }
                .disabled(speech.working || voice.phase.isBusy || speech.isInUse)
                .onChange(of: model) { _, _ in Task { await speech.unload() } }
                Text("Compressed Turbo is the recommended starting point for multilingual speech. Base is smaller and faster. First preparation can take several minutes.")
                    .font(.caption).foregroundStyle(.secondary)
                if speech.working { ProgressView(value: speech.progress).accessibilityLabel("Model download progress") }
                Text(speech.status).textSelection(.enabled).accessibilityLabel("Speech model status: \(speech.status)")
                HStack {
                    if speech.working { Button("Cancel") { speech.cancel() } }
                    else {
                        Button(speech.installed.contains(model) ? "Verify and prepare" : "Download and prepare") { speech.prepare(allowDownload: true) }
                        if speech.ready { Button("Unload") { Task { await speech.unload() } } }
                        if let selected = speech.selected, speech.installed.contains(model) {
                            Button("Delete model", role: .destructive) { Task { await speech.delete(selected) } }
                        }
                    }
                }.disabled(voice.phase.isBusy || speech.isInUse)
                Picker("Speech language", selection: $language) {
                    Text("Detect automatically").tag("")
                    ForEach(Self.languages, id: \.0) { code, name in Text(name).tag(code) }
                }.disabled(voice.phase.isBusy || speech.isInUse)
                Picker("Unload model when idle", selection: $idleMinutes) {
                    Text("Keep loaded").tag(0)
                    Text("After 2 minutes").tag(2)
                    Text("After 5 minutes").tag(5)
                    Text("After 15 minutes").tag(15)
                }.onChange(of: idleMinutes) { _, _ in if !voice.phase.isBusy { speech.scheduleIdleUnload() } }
                Text("After unloading, prepare the model again before speaking. A recording is limited to two minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shortcuts and insertion") {
                KeyboardShortcuts.Recorder("Hold to dictate:", name: .dictateHold)
                KeyboardShortcuts.Recorder("Toggle dictation:", name: .dictateToggle)
                KeyboardShortcuts.Recorder("Toggle voice task:", name: .voiceTask)
                Text("Wait for Listening before speaking. Release the hold shortcut or press the toggle shortcut again to finish. Escape cancels. Tasks always open for review before saving.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Restore clipboard after pasting", isOn: $restoreClipboard)
                Button("Allow text insertion…") { TextInsertionCoordinator.shared.requestAccessibility() }
            }
            if !voice.original.isEmpty {
                Section("Last transcript · kept until the next recording or quit") {
                    Text(voice.original).textSelection(.enabled)
                    Button("Copy original") { voice.copy(originalOnly: true) }
                    if let metrics = voice.metrics {
                        Text("Cleanup: \(metrics.elapsedMilliseconds) ms\(metrics.usage?.inputTokens.map { " · \($0) input tokens" } ?? "")\(metrics.usage?.outputTokens.map { " · \($0) output tokens" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                        if let cost = metrics.estimatedCost { Text("Estimated API cost: \(cost, format: .currency(code: "USD"))").font(.caption) }
                    }
                }
            }
        }
        .formStyle(.grouped).navigationTitle("Voice")
        .task { microphones = MicrophoneDevice.available(); await speech.refreshInstalled() }
    }

    private static let languages: [(String, String)] = Constants.languageCodes.map { code in
        (code, Locale.current.localizedString(forLanguageCode: code) ?? Constants.languages.first(where: { $0.value == code })?.key.capitalized ?? code)
    }.sorted { $0.1 < $1.1 }
}

@MainActor
final class VoiceStatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init(coordinator: VoiceCoordinator) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 210), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true; hidesOnDeactivate = false; isReleasedWhenClosed = false
        level = .statusBar; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear; isOpaque = false; hasShadow = true
        contentView = NSHostingView(rootView: VoiceStatusView(voice: coordinator, recorder: coordinator.recorder))
    }
    func showWithoutActivation() {
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            setFrameOrigin(NSPoint(x: screen.frame.midX - frame.width / 2, y: screen.visibleFrame.maxY - frame.height - 10))
        }
        orderFrontRegardless()
    }
}

private struct VoiceStatusView: View {
    @ObservedObject var voice: VoiceCoordinator
    @ObservedObject var recorder: AudioRecorder
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(voice.mode == .task ? "Voice task" : "Dictation", systemImage: voice.phase == .recording ? "mic.fill" : "waveform")
                    .font(.headline).foregroundStyle(voice.phase == .recording ? .red : .primary)
                Spacer()
                if !voice.phase.isBusy {
                    Button { voice.dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss voice status")
                }
            }
            Text(voice.status).font(.callout).fixedSize(horizontal: false, vertical: true)
            if voice.phase == .recording {
                ProgressView(value: Double(recorder.level)).accessibilityLabel("Microphone level")
                Text("\(Int(recorder.duration)) / 120 seconds").font(.caption).monospacedDigit()
            } else if voice.phase.isBusy { ProgressView().controlSize(.small) }
            HStack {
                if voice.phase == .recording { Button("Finish") { voice.stop() } }
                if voice.phase.isBusy { Button("Cancel") { voice.cancel() } }
                else if !voice.original.isEmpty {
                    Button("Copy original") { voice.copy(originalOnly: true) }
                    if voice.result != voice.original { Button("Copy result") { voice.copy() } }
                    if voice.phase == .review {
                        Button("Use original") { voice.useOriginal() }
                        Button("Retry cleanup") { voice.retryProcessing() }
                    }
                }
                Spacer(minLength: 0)
            }.controlSize(.small)
        }.padding(16).frame(width: 400, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
