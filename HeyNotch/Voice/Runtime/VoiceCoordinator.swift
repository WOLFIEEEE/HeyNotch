import AppKit
import AVFoundation
import Combine
import KeyboardShortcuts

@MainActor
final class VoiceCoordinator: ObservableObject {
    static let shared = VoiceCoordinator()
    @Published private(set) var phase: VoicePhase = .idle
    @Published private(set) var status = "Ready when you are."
    @Published private(set) var original = ""
    @Published private(set) var result = ""
    @Published private(set) var mode: VoiceMode = .dictation
    @Published private(set) var destination = ""
    @Published private(set) var metrics: CleanupResult?
    let recorder = AudioRecorder()
    let speech = SpeechController.shared
    private let insertion = TextInsertionClient()
    private var operation = UUID()
    private var target: InsertionTarget?
    private var targetRequest: Task<InsertionResponse, Never>?
    private var job: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var observers: [Any] = []
    private var escapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var panel: VoiceStatusPanel?
    private var held = false
    private var processingRevision = UUID()
    private var style: CleanupStyle = .off
    private var failurePreference: ProcessingFailurePreference = .review
    private var pasteAttempted = false
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var releaseWatchdog: Task<Void, Never>?

    init() {
        recorder.onLimit = { [weak self] in self?.stop() }
        recorder.onFailure = { [weak self] error in self?.cancel(message: error.localizedDescription) }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.phase.isBusy { self.cancel(message: "Voice input stopped because this Mac is low on memory. Your transcript is kept if available.") }
                if self.speech.working { self.speech.cancel() } else { await self.speech.unload() }
            }
        }
        pressure.resume(); memoryPressure = pressure
        observers.append(NotificationCenter.default.addObserver(forName: .processingConfigurationChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if self?.phase == .processing { self?.cancel(message: "Processing settings changed. Your original text is available to copy.") }
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel(message: "Recording stopped because this Mac is going to sleep."); await self?.speech.unload() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel(message: "Stopped.") }
        })
    }

    func registerShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .dictateHold) { [weak self] in self?.start(.dictation, hold: true) }
        KeyboardShortcuts.onKeyUp(for: .dictateHold) { [weak self] in
            guard self?.held == true else { return }
            self?.held = false; self?.stop()
        }
        KeyboardShortcuts.onKeyUp(for: .dictateToggle) { [weak self] in self?.toggle(.dictation) }
        KeyboardShortcuts.onKeyUp(for: .voiceTask) { [weak self] in self?.toggle(.task) }
    }

    func toggle(_ requested: VoiceMode) {
        if phase == .recording { stop() } else { start(requested, hold: false) }
    }

    func start(_ requested: VoiceMode, hold: Bool) {
        guard !phase.isBusy else { return }
        guard !speech.isInUse else {
            status = "Finish meeting transcription before starting dictation."; show(); return
        }
        guard UserDefaults.standard.bool(forKey: "voice.enabled") else {
            status = "Enable voice input and prepare a model in Voice settings."; show(); return
        }
        guard speech.ready else {
            status = "Prepare the speech model in Voice settings. Wait for Ready, then start again."; show(); return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            status = VoiceError.microphoneDenied.localizedDescription; show(); return
        }
        let id = UUID(); operation = id; held = hold; mode = requested; target = nil; pasteAttempted = false
        metrics = nil
        let preferences = ProcessingSettingsStore.shared.preferences
        processingRevision = preferences.revision
        style = preferences.enabled ? preferences.cleanupStyle : .off
        failurePreference = preferences.failurePreference
        destination = ""
        targetRequest?.cancel(); targetRequest = nil
        if requested == .dictation, let app = NSWorkspace.shared.frontmostApplication,
           let bundle = app.bundleIdentifier, bundle != Bundle.main.bundleIdentifier {
            destination = app.localizedName ?? bundle
            let request = CaptureInsertionRequest(operationID: id, processID: app.processIdentifier,
                                                  bundleIdentifier: bundle, validitySeconds: 300)
            targetRequest = Task { await insertion.capture(request) }
        }
        do {
            try recorder.start(deviceUID: UserDefaults.standard.string(forKey: "voice.microphone") ?? "")
            speech.beginUse(); original = ""; result = ""
            phase = .recording
            status = requested == .task ? "Listening for a task…" : "Listening… \(hold ? "Release the shortcut to finish." : "Press the shortcut again to finish.")"
            show(); installEscape()
            releaseWatchdog?.cancel()
            if hold, let shortcut = KeyboardShortcuts.getShortcut(for: .dictateHold) {
                releaseWatchdog = Task {
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                    while operation == id && phase == .recording && held {
                        if !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(shortcut.carbonKeyCode)) { stop(); return }
                        do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                    }
                }
            }
            watchdog?.cancel()
            watchdog = Task {
                // Independent wall-clock limit also recovers from a lost key-up or a stalled input device.
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                if operation == id && phase == .recording { stop() }
            }
        } catch { cancel(message: error.localizedDescription) }
    }

    func stop() {
        guard phase == .recording else { return }
        held = false; watchdog?.cancel(); watchdog = nil
        releaseWatchdog?.cancel(); releaseWatchdog = nil
        guard let audio = recorder.stop() else { cancel(message: VoiceError.invalidAudio.localizedDescription); return }
        let id = operation
        phase = .transcribing; status = "Transcribing on this Mac…"
        job = Task {
            do {
                let language = UserDefaults.standard.string(forKey: "voice.language") ?? ""
                let text = try await speech.engine.transcribe(audio, language: language.isEmpty ? nil : language)
                try Task.checkCancellation()
                guard operation == id else { return }
                original = text; result = text
                if let captured = await targetRequest?.value, captured.status == .targetReady { target = captured.target }
                try Task.checkCancellation()
                if mode == .task {
                    phase = .finished; status = "Task transcribed. Review it before saving."
                    TaskController.shared.propose(text)
                    finishSession(); return
                }
                try await processAndInsert(id: id)
            } catch {
                guard operation == id else { return }
                phase = original.isEmpty ? .finished : .review
                status = error is CancellationError ? "Cancelled. Your original text is available to copy." : error.localizedDescription
                finishSession()
            }
        }
    }

    private func processAndInsert(id: UUID) async throws {
        if style != .off {
            phase = .processing; status = "Cleaning up with the selected model…"
            do {
                guard processingRevision == ProcessingSettingsStore.shared.preferences.revision else { throw ProcessingError.configurationChanged }
                let snapshot = try await ProcessingController.shared.snapshot()
                let cleaned = try await TranscriptCleanup(api: ProcessingController.shared.api).clean(original, style: style, snapshot: snapshot)
                try Task.checkCancellation()
                guard operation == id, processingRevision == ProcessingSettingsStore.shared.preferences.revision else { throw ProcessingError.configurationChanged }
                result = cleaned.text; metrics = cleaned
            } catch {
                try Task.checkCancellation()
                guard operation == id, processingRevision == ProcessingSettingsStore.shared.preferences.revision else { throw ProcessingError.configurationChanged }
                if failurePreference == .useOriginal { result = original }
                else { throw error }
            }
        }
        try Task.checkCancellation()
        guard operation == id else { return }
        await insertRetained(id: id)
    }

    private func insertRetained(id: UUID) async {
        guard let target, !pasteAttempted else {
            phase = .review; status = "Your transcript is ready. Copy it into the field you want."; finishSession(); return
        }
        pasteAttempted = true
        phase = .inserting; status = "Pasting into \(destination)…"
        let restore = UserDefaults.standard.object(forKey: TextInsertionCoordinator.restoreKey) as? Bool ?? true
        let response = await insertion.insert(TextInsertionRequest(operationID: id, target: target, text: result, restoreClipboard: restore))
        guard operation == id else { return }
        phase = response.status == .pasteSent ? .finished : .review
        status = response.status.message
        finishSession()
    }

    func useOriginal() {
        guard phase == .review, !original.isEmpty else { return }
        result = original
        let id = operation
        job = Task { await insertRetained(id: id) }
    }

    func retryProcessing() {
        guard phase == .review, !original.isEmpty, !pasteAttempted else { return }
        let preferences = ProcessingSettingsStore.shared.preferences
        processingRevision = preferences.revision
        style = preferences.enabled ? preferences.cleanupStyle : .off
        let id = operation
        job = Task {
            do { try await processAndInsert(id: id) }
            catch { if operation == id { phase = .review; status = error.localizedDescription; finishSession() } }
        }
    }

    func cancel(message: String = "Cancelled. Your original text is still available to copy.") {
        insertion.cancel(operation); operation = UUID()
        job?.cancel(); job = nil; targetRequest?.cancel(); targetRequest = nil
        watchdog?.cancel(); watchdog = nil; recorder.discard(); held = false
        releaseWatchdog?.cancel(); releaseWatchdog = nil
        target = nil; phase = original.isEmpty ? .finished : .review; status = message
        finishSession()
    }

    func copy(originalOnly: Bool = false) {
        let text = originalOnly ? original : result
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        status = NSPasteboard.general.setString(text, forType: .string) ? "Text copied." : "Could not copy. Your transcript is still available."
    }
    func dismiss() { if !phase.isBusy { panel?.orderOut(nil) } }
    private func show() {
        if panel == nil { panel = VoiceStatusPanel(coordinator: self) }
        panel?.showWithoutActivation()
    }
    private func finishSession() {
        removeEscape(); speech.endUse()
    }
    private func installEscape() {
        removeEscape()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel(); return nil }; return event
        }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel() }
        }
    }
    private func removeEscape() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        if let globalEscapeMonitor { NSEvent.removeMonitor(globalEscapeMonitor); self.globalEscapeMonitor = nil }
    }
}
