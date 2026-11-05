import AppKit
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MeetingCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = MeetingCoordinator()
    @Published private(set) var phase: MeetingPhase = .idle
    @Published private(set) var status = "Choose a call app, then start when everyone is ready."
    @Published private(set) var segments: [MeetingTranscriptSegment] = []
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var queued = 0
    @Published private(set) var microphoneAudioSeconds: Double = 0
    @Published private(set) var callAudioSeconds: Double = 0
    @Published private(set) var microphoneLevel: Float = 0
    @Published private(set) var callAudioLevel: Float = 0
    @Published private(set) var activity = MeetingActivity()
    @Published private(set) var suggestion: MeetingActivity?
    @Published private(set) var snoozedUntil: Date?
    @Published private(set) var notificationStatus = "The in-app reminder works without notification permission."
    @Published private(set) var historySaveIssue: String?
    @Published var selectedApp = ""
    @Published var microphoneOnly = false
    @Published private(set) var apps: [MeetingApp] = []
    let microphone = AudioRecorder()
    let speech = SpeechController.shared
    private let systemAudio = MeetingSystemAudio()
    private var policy = MeetingSuggestionPolicy()
    private var polling: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var startup: Task<Void, Never>?
    private var waitingForMicrophonePermission = false
    private var decoding: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var pending = MeetingAudioQueue()
    private var session = UUID()
    private var savedSession: UUID?
    @Published private var savedSegmentCount = 0
    private var started: Date?
    private var startedHostTime: TimeInterval?
    private var callSource = "All system audio"
    private var language: String?
    private var channelMicOnly = false
    private var lastDrainHostTime: TimeInterval?
    private var discardUnfinished = false
    private var lastTexts: [MeetingAudioSource: (offset: TimeInterval, text: String)] = [:]
    private var window: NSWindowController?
    private var banner: MeetingSuggestionPanel?
    private var bannerExpiry: Date?
    private var observers: [Any] = []
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var finalMessage: String?
    private var promptGeneration = UUID()
    private var screenLocked = false
    private var systemAsleep = false
    private var historySuppressed = false
    private var lastHistoryRefresh = Date.distantPast
    private var notificationPreferenceRevision = UUID()

    var enabled: Bool { UserDefaults.standard.object(forKey: "meetings.suggest") as? Bool ?? true }
    var cameraSuggestions: Bool { UserDefaults.standard.object(forKey: "meetings.camera") as? Bool ?? true }
    var excludedApps: Set<String> { Set(UserDefaults.standard.stringArray(forKey: "meetings.excludedApps") ?? []) }
    var exportText: String { MeetingTranscriptTools.export(segments, format: .plainText, started: started, callSource: callSource) }
    var historySessionID: UUID { session }
    var isHistorySuppressedForSession: Bool { historySuppressed }
    var sessionTitle: String {
        MeetingHistoryStore.shared.entries.first { $0.id == session }?.title
            ?? started.map { "Meeting · " + DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) }
            ?? "Meeting transcript"
    }
    var hasUnsavedTranscript: Bool {
        guard !segments.isEmpty, savedSession != session || savedSegmentCount < segments.count else { return false }
        return MeetingHistoryStore.shared.entries.first { $0.id == session }?.segments != segments
    }

    override private init() {
        super.init()
        microphone.onLimit = { [weak self] in self?.stop(message: "The two-hour session limit was reached. Start a new session to continue.") }
        microphone.onFailure = { [weak self] error in self?.stop(message: error.localizedDescription) }
        systemAudio.onFailure = { [weak self] error in self?.stop(message: error.localizedDescription) }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemAsleep = true; self?.hideSuggestion(); self?.stop(message: "Recording stopped because this Mac is going to sleep.") }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenLocked = true; self?.hideSuggestion(); self?.stop(message: "Recording stopped because this Mac was locked.") }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemAsleep = false; self?.policy.resetActivity() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenLocked = false; self?.policy.resetActivity() }
        })
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            Task { @MainActor in self?.stop(message: "Recording stopped because this Mac is low on memory.", discardPending: true) }
        }
        pressure.resume(); memoryPressure = pressure
    }

    func startMonitoring() {
        guard polling == nil else { return }
        MeetingNotifications.shared.configure()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func poll() {
        let now = Date()
        if now.timeIntervalSince(lastHistoryRefresh) >= 900 {
            lastHistoryRefresh = now; MeetingHistoryStore.shared.reload()
        }
        if !enabled || screenLocked || systemAsleep {
            hideSuggestion()
            if activity != MeetingActivity() { activity = MeetingActivity() }
            return
        }
        var found = MeetingActivityMonitor.sample(excluded: excludedApps)
        if !cameraSuggestions { found.cameraInUse = false }
        // Polling still observes every sample. Only actual changes need to
        // invalidate the app's menu, settings and notch view hierarchy.
        if activity != found { activity = found }
        if phase.isBusy { hideSuggestion() }
        let shouldPrompt = policy.observe(found, at: now, enabled: enabled, busy: phase.isBusy || VoiceCoordinator.shared.phase.isBusy)
        if phase.isBusy { policy.dismiss() }
        if snoozedUntil != policy.snoozedUntil { snoozedUntil = policy.snoozedUntil }
        if shouldPrompt { presentSuggestion(found) }
        if let bannerExpiry, now >= bannerExpiry { hideSuggestion() }
    }

    private func presentSuggestion(_ value: MeetingActivity) {
        suggestion = value; bannerExpiry = Date().addingTimeInterval(35); promptGeneration = UUID()
        let generation = promptGeneration
        Task {
            let delivered = await MeetingNotifications.shared.deliver(value, token: generation)
            guard promptGeneration == generation, suggestion != nil else { return }
            if !delivered { showBanner() }
        }
    }
    private func showBanner() {
        if banner == nil { banner = MeetingSuggestionPanel(coordinator: self) }
        banner?.showWithoutActivation()
    }
    func previewReminder() {
        presentSuggestion(MeetingActivity(microphoneApps: [.init(id: "", name: "A test call app")]))
    }
    func hideSuggestion() {
        promptGeneration = UUID()
        if suggestion != nil { suggestion = nil }
        bannerExpiry = nil; banner?.orderOut(nil)
        MeetingNotifications.shared.clear()
    }
    func dismissSuggestion() { policy.dismiss(); hideSuggestion() }
    func snooze() { policy.snooze(at: Date()); snoozedUntil = policy.snoozedUntil; hideSuggestion() }
    func resumeSuggestions() { policy.resume(); snoozedUntil = nil }
    func settingsChanged() { if !enabled { hideSuggestion() }; objectWillChange.send() }
    func exclude(_ app: MeetingApp) {
        var ids = excludedApps; ids.insert(app.id)
        UserDefaults.standard.set(Array(ids).sorted(), forKey: "meetings.excludedApps")
        hideSuggestion(); objectWillChange.send()
    }
    func include(_ id: String) {
        var ids = excludedApps; ids.remove(id)
        UserDefaults.standard.set(Array(ids).sorted(), forKey: "meetings.excludedApps"); objectWillChange.send()
    }
    func respondToNotification(_ action: String, token: UUID) {
        guard token == promptGeneration, suggestion != nil else { return }
        if action == "snooze" { snooze() }
        else if action == "dismiss" { dismissSuggestion() }
        else { openSuggestion() }
    }
    func openSuggestion() {
        if !phase.isBusy, segments.isEmpty { selectedApp = suggestion?.microphoneApps.first?.id ?? "" }
        dismissSuggestion(); showWindow()
    }
    func setNotificationsEnabled(_ enabled: Bool) {
        let revision = UUID(); notificationPreferenceRevision = revision
        if !enabled {
            MeetingNotifications.shared.clear()
            notificationStatus = "Notifications are off. The in-app reminder is still available."
            if suggestion != nil { showBanner() }
            return
        }
        notificationStatus = "Waiting for notification permission…"
        Task {
            let result = await MeetingNotifications.shared.requestPermission()
            // Turning the setting off while macOS is asking must win over a late reply.
            guard notificationPreferenceRevision == revision,
                  UserDefaults.standard.bool(forKey: "meetings.systemNotifications") else { return }
            UserDefaults.standard.set(result.allowed, forKey: "meetings.systemNotifications")
            notificationStatus = result.message
        }
    }
    func refreshApps() {
        apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }.compactMap {
            guard let id = $0.bundleIdentifier else { return nil }
            return MeetingApp(id: id, name: $0.localizedName ?? id)
        }.sorted { $0.name < $1.name }
    }

    func showWindow() {
        refreshApps()
        if window == nil {
            let view = MeetingWorkspaceView(coordinator: self)
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            panel.title = "Meeting Transcription"; panel.minSize = NSSize(width: 600, height: 500)
            panel.contentView = NSHostingView(rootView: view); panel.isReleasedWhenClosed = false
            panel.delegate = self; panel.center(); window = NSWindowController(window: panel)
        }
        window?.showWindow(nil); window?.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if phase.isBusy { stop(message: "Recording stopped when the transcript window closed. Reopen it from the HeyNotch menu.") }
        return true
    }

    func begin() {
        guard !phase.isBusy, segments.isEmpty else { return }
        guard !speech.isInUse, !VoiceCoordinator.shared.phase.isBusy else { status = "Finish dictation before starting meeting transcription."; return }
        guard speech.ready else { status = "Prepare the speech model below. Wait for Ready, then choose Start."; return }
        hideSuggestion(); policy.dismiss()
        phase = .starting; status = "Requesting access. Recording has not started yet…"
        let id = UUID(); session = id; finalMessage = nil; lastTexts = [:]; elapsed = 0
        historySuppressed = false; historySaveIssue = nil
        savedSession = nil; savedSegmentCount = 0
        discardUnfinished = false; startedHostTime = nil; microphoneAudioSeconds = 0; callAudioSeconds = 0
        microphoneLevel = 0; callAudioLevel = 0
        channelMicOnly = microphoneOnly
        let bundleID = selectedApp
        callSource = channelMicOnly ? "Not captured · microphone only" : (apps.first { $0.id == bundleID }?.name ?? (bundleID.isEmpty ? "All system audio" : bundleID))
        language = UserDefaults.standard.string(forKey: "voice.language").flatMap { $0.isEmpty ? nil : $0 }
        speech.beginUse("meeting")
        startup = Task {
            do {
                try Task.checkCancellation()
                guard session == id else { return }
                waitingForMicrophonePermission = true
                let allowed = await microphone.requestPermission()
                // Cancel can finish immediately while this system prompt remains
                // open. Its late reply must not touch a later capture attempt.
                guard session == id else { return }
                waitingForMicrophonePermission = false
                guard allowed else { throw VoiceError.microphoneDenied }
                try Task.checkCancellation()
                if !channelMicOnly { try await systemAudio.start(bundleID: bundleID) }
                try Task.checkCancellation()
                guard session == id else { throw CancellationError() }
                startedHostTime = Self.hostTime()
                try microphone.start(deviceUID: UserDefaults.standard.string(forKey: "voice.microphone") ?? "", maximumDuration: 7200)
                started = Date(); lastDrainHostTime = startedHostTime; phase = .recording
                status = "Recording \(channelMicOnly ? "your microphone" : "your microphone and call audio") · transcribing on this Mac."
                clock = Task {
                    while phase == .recording && session == id {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        elapsed = max(0, Self.hostTime() - (startedHostTime ?? Self.hostTime()))
                        refreshAudioHealth()
                        if !channelMicOnly, !bundleID.isEmpty,
                           !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) {
                            stop(message: "Recording stopped because the selected call app closed."); return
                        }
                        if elapsed >= 7200 { stop(message: "The two-hour session limit was reached."); return }
                        if Self.hostTime() - (lastDrainHostTime ?? 0) >= 20 { drain() }
                    }
                }
            } catch {
                guard session == id else { return }
                waitingForMicrophonePermission = false
                await systemAudio.stop(); systemAudio.discard(); microphone.discard()
                guard session == id else { return }
                phase = .finished; status = error is CancellationError ? "Start cancelled. No transcript was saved." : error.localizedDescription
                speech.endUse("meeting")
            }
            if session == id { startup = nil }
        }
    }

    private func drain() {
        lastDrainHostTime = Self.hostTime()
        // Each channel is committed independently. A broken system stream must
        // never discard the healthy microphone chunk that was just drained.
        enqueue(microphone.drainTimed(), source: .microphone)
        do {
            let call = channelMicOnly ? nil : try systemAudio.drainTimed()
            enqueue(call, source: .call)
            if pending.count > 4 { stop(message: MeetingError.backlog.localizedDescription) }
        } catch {
            addGap(source: .call, offset: elapsed, text: "Call audio capture was interrupted. Any valid audio before the interruption is retained.")
            stop(message: error.localizedDescription)
        }
    }
    private func enqueue(_ captured: TimedRecordedAudio?, source: MeetingAudioSource) {
        guard let captured, captured.audio.isSpeechCandidate else { return }
        let audio = captured.audio
        let offset = max(0, captured.startedAtHostTime.map { $0 - (startedHostTime ?? $0) } ?? (elapsed - audio.duration))
        do {
            // Downsample before queuing, so high-rate microphones do not inflate
            // a long call's queue. At most six twenty-second chunks are retained.
            let samples = try LocalSpeechEngine.resample(audio)
            guard pending.append(MeetingAudioChunk(source: source, offset: offset, audio: RecordedAudio(monoSamples: samples, sampleRate: 16_000, sourceChannels: audio.sourceChannels))) else {
                addGap(source: source, offset: offset, text: "This section exceeded the pending-audio limit and was not retained.")
                stop(message: MeetingError.backlog.localizedDescription); return
            }
            queued = pending.count; consume()
        } catch { addGap(source: source, offset: offset, text: "This section of audio could not be read.") }
    }
    private func consume() {
        guard decoding == nil else { return }
        let id = session
        decoding = Task {
            while !pending.isEmpty && session == id && !Task.isCancelled {
                let chunk = pending.removeFirst(); queued = pending.count + 1
                do {
                    let text = try await speech.engine.transcribe(chunk.audio, language: language)
                    try Task.checkCancellation()
                    guard session == id else { return }
                    let previous = lastTexts[chunk.source]
                    let clean = MeetingTranscript.removingOverlap(text, after: previous.flatMap { chunk.overlapContainsSpeech && chunk.offset - $0.offset < 25 ? $0.text : nil })
                    lastTexts[chunk.source] = (chunk.offset, text)
                    if !clean.isEmpty {
                        segments.append(.init(source: chunk.source, offset: chunk.offset, text: clean))
                        persistHistory()
                    }
                } catch {
                    if !(error is CancellationError) {
                        addGap(source: chunk.source, offset: chunk.offset, text: "Speech could not be transcribed in this section.")
                    }
                }
            }
            guard session == id else { return }
            decoding = nil; queued = pending.count
            if phase == .finishing && stopping == nil { finish() }
        }
    }
    private func addGap(source: MeetingAudioSource, offset: TimeInterval, text: String) {
        segments.append(.init(source: source, offset: offset, text: text, isGap: true))
        persistHistory()
    }
    func stop(message: String? = nil, discardPending: Bool = false) {
        if discardPending { discardUnfinished = true }
        if phase == .finishing && discardPending {
            finalMessage = message; decoding?.cancel(); pending.removeAll()
            addGap(source: .call, offset: elapsed, text: "Remaining microphone and call audio was discarded because memory was low.")
            if decoding == nil && stopping == nil { finish() }
            return
        }
        guard phase == .recording || phase == .starting else { return }
        finalMessage = message; clock?.cancel(); clock = nil
        if phase == .starting {
            startup?.cancel()
            if waitingForMicrophonePermission {
                // No capture resources exist yet. Releasing this attempt makes
                // Cancel useful even if macOS never answers its permission prompt.
                session = UUID(); startup = nil; waitingForMicrophonePermission = false
                phase = .finished; speech.endUse("meeting")
                status = "Start cancelled. Recording has not started."
            } else { status = "Cancelling start…" }
            return
        }
        phase = .finishing; status = "Recording stopped. Finishing the remaining audio…"
        elapsed = max(0, Self.hostTime() - (startedHostTime ?? Self.hostTime()))
        refreshAudioHealth()
        let mic = microphone.stopTimed()
        microphoneLevel = 0; callAudioLevel = 0
        if discardPending {
            decoding?.cancel(); pending.removeAll()
            addGap(source: .microphone, offset: elapsed, text: "Unfinished audio was discarded because memory was low.")
        } else { enqueue(mic, source: .microphone) }
        stopping = Task {
            await systemAudio.stop()
            if !channelMicOnly && !discardUnfinished {
                do { enqueue(try systemAudio.drainTimed(overlap: 0, recoveringValidAudio: true), source: .call) }
                catch { addGap(source: .call, offset: elapsed, text: "The last section of call audio could not be read.") }
            }
            systemAudio.discard(); stopping = nil
            if decoding == nil { finish() }
        }
    }
    private func finish() {
        phase = .finished; queued = 0; speech.endUse("meeting")
        persistHistory()
        status = finalMessage ?? (segments.isEmpty ? "Finished. No clear speech was detected." : "Transcript ready. Copy or save it before starting a new session or quitting.")
    }
    private static func hostTime() -> TimeInterval { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }
    private func refreshAudioHealth() {
        microphoneAudioSeconds = microphone.duration; microphoneLevel = microphone.level
        let health = systemAudio.health
        callAudioSeconds = health.duration; callAudioLevel = health.level
    }
    func clear() {
        guard !phase.isBusy else { return }
        session = UUID(); savedSession = nil; savedSegmentCount = 0
        historySuppressed = false; historySaveIssue = nil
        segments = []; lastTexts = [:]; pending.removeAll(); started = nil; elapsed = 0; phase = .idle
        startedHostTime = nil; microphoneAudioSeconds = 0; callAudioSeconds = 0; microphoneLevel = 0; callAudioLevel = 0
        status = "Choose a call app, then start when everyone is ready."
    }
    func copy() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(exportText, forType: .string) }
    func setHistoryEnabled(_ enabled: Bool) {
        MeetingHistoryStore.shared.setEnabled(enabled)
        if enabled { persistHistory() } else { historySaveIssue = nil }
    }
    func suppressHistoryForCurrentSession() { historySuppressed = true; historySaveIssue = nil; objectWillChange.send() }
    func retryHistorySave() {
        MeetingHistoryStore.shared.reload()
        persistHistory()
    }
    private func persistHistory() {
        guard !historySuppressed, MeetingHistoryStore.shared.enabled, !segments.isEmpty, let started else { return }
        let entry = MeetingHistoryEntry(id: session, startedAt: started, updatedAt: Date(), title: sessionTitle,
                                        callSource: callSource, elapsed: elapsed, completed: phase == .finished, segments: segments)
        if MeetingHistoryStore.shared.upsert(entry) { historySaveIssue = nil }
        else {
            historySaveIssue = "This session’s latest text has not been saved to history. Copy or export it before quitting."
        }
    }
    func createTask(from segment: MeetingTranscriptSegment) {
        guard !segment.isGap else { return }
        let provenance = started.map {
            sessionTitle + " · recorded " + DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)
        } ?? sessionTitle
        TaskController.shared.proposeMeetingPassage(text: segment.text, timestamp: segment.timestamp,
                                                  source: segment.source.rawValue, sessionTitle: provenance)
    }
    func save(format: MeetingTranscriptExportFormat = .plainText) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .plainText]
        panel.nameFieldStringValue = "Meeting transcript.\(format.fileExtension)"
        let snapshot = MeetingTranscriptTools.export(segments, format: format, started: started, callSource: callSource)
        let snapshotSession = session
        let snapshotSegmentCount = segments.count
        guard let parent = window?.window else { return }
        panel.beginSheetModal(for: parent) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try snapshot.write(to: url, atomically: true, encoding: .utf8)
                // A save covers exactly the exported snapshot, not segments
                // decoded while the save panel was open or a newer session.
                guard let self, self.session == snapshotSession else { return }
                self.savedSession = snapshotSession
                self.savedSegmentCount = max(self.savedSegmentCount, snapshotSegmentCount)
            }
            catch { self?.status = "The transcript could not be saved. Choose another location or copy the text." }
        }
    }
}
