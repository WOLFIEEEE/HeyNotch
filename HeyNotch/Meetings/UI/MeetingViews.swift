import AppKit
import SwiftUI

struct MeetingSettingsView: View {
    @ObservedObject private var meeting = MeetingCoordinator.shared
    @AppStorage("meetings.suggest") private var enabled = true
    @AppStorage("meetings.camera") private var camera = true
    @AppStorage("meetings.systemNotifications") private var notifications = false
    @State private var excludeApp = ""
    var body: some View {
        Form {
            Section("Automatic reminders") {
                Toggle("Offer transcription when another app uses my microphone", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in meeting.settingsChanged() }
                Toggle("Also suggest when my camera is in use", isOn: $camera).disabled(!enabled)
                Text("HeyNotch checks device activity without listening or viewing your camera. Activity can mean a call, a recording, or something else. You always choose when recording starts.")
                    .font(.callout).foregroundStyle(.secondary)
                if !MeetingActivityMonitor.microphoneDetectionAvailable {
                    Text("Microphone activity detection needs macOS 14.2 or later. Camera reminders and manual transcription are still available.").font(.caption)
                }
                HStack {
                    Button("Preview reminder") { meeting.previewReminder() }
                    Button("Snooze for 1 hour") { meeting.snooze() }.disabled(!enabled)
                }
                if let until = meeting.snoozedUntil, until > Date() {
                    HStack { Text("Snoozed until \(until, style: .time)"); Button("Resume") { meeting.resumeSuggestions() } }
                }
                Text("One reminder per activity session, with a two-minute quiet period and a 15-minute cooldown. HeyNotch’s own microphone and camera use is ignored.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("Use macOS notifications", isOn: $notifications)
                    .onChange(of: notifications) { _, value in meeting.setNotificationsEnabled(value) }
                Text(meeting.notificationStatus).font(.caption).foregroundStyle(.secondary)
                Text("macOS notifications follow Focus settings. Otherwise a quiet reminder appears below the notch without switching apps.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Ignored microphone apps") {
                Picker("App", selection: $excludeApp) {
                    Text("Choose an app…").tag("")
                    ForEach(meeting.apps) { Text($0.name).tag($0.id) }
                }
                HStack {
                    Button("Ignore app") { if let app = meeting.apps.first(where: { $0.id == excludeApp }) { meeting.exclude(app); excludeApp = "" } }.disabled(excludeApp.isEmpty)
                    Button("Refresh apps") { meeting.refreshApps() }
                }
                ForEach(meeting.excludedApps.sorted(), id: \.self) { id in
                    HStack { Text(meeting.apps.first { $0.id == id }?.name ?? id); Spacer(); Button("Remove") { meeting.include(id) } }
                }
                Text("Camera-only reminders cannot identify the app. Turn off camera suggestions above if you do not want them.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Meeting transcription") {
                Button("Open Meeting Transcription…") { meeting.showWindow() }
                Text("Capture your microphone and the call audio. Transcription stays on this Mac and is never automatically pasted into another app or sent to your AI provider. Headphones help keep the two channels separate.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Microphone and Screen & System Audio Recording access are requested when you choose Start. No video is recorded. Let other participants know before recording.").font(.caption).foregroundStyle(.secondary)
            }
            MeetingHistorySettingsSection()
        }
        .formStyle(.grouped).navigationTitle("Meetings")
        .task { meeting.refreshApps() }
    }
}

struct MeetingWorkspaceView: View {
    @ObservedObject var coordinator: MeetingCoordinator
    @ObservedObject private var speech = SpeechController.shared
    @ObservedObject private var history = MeetingHistoryStore.shared
    @AppStorage("voice.microphone") private var microphone = ""
    @State private var microphones: [MicrophoneDevice] = []
    @State private var confirmClear = false
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(coordinator.phase == .recording ? "Recording" : "Meeting transcription", systemImage: coordinator.phase == .recording ? "record.circle.fill" : "waveform")
                        .font(.title2.weight(.semibold)).foregroundStyle(coordinator.phase == .recording ? Color.red : Color.primary)
                    Spacer()
                    Text(MeetingTranscriptSegment.timestamp(coordinator.elapsed)).monospacedDigit().accessibilityLabel("Session duration")
                }
                Text(coordinator.status).font(.callout).textSelection(.enabled).accessibilityLabel("Meeting status: \(coordinator.status)")
                if coordinator.phase == .recording {
                    HStack(spacing: 20) {
                        audioHealth("Microphone", seconds: coordinator.microphoneAudioSeconds, level: coordinator.microphoneLevel)
                        if !coordinator.microphoneOnly {
                            audioHealth("Call audio", seconds: coordinator.callAudioSeconds, level: coordinator.callAudioLevel)
                        }
                    }
                }
                if coordinator.phase.isBusy {
                    HStack {
                        if coordinator.queued > 0 { ProgressView().controlSize(.small); Text("\(coordinator.queued) audio sections remaining").font(.caption) }
                        Spacer()
                        Button(coordinator.phase == .starting ? "Cancel start" : "Stop transcription") { coordinator.stop() }
                            .keyboardShortcut(".", modifiers: .command).disabled(coordinator.phase == .finishing)
                    }
                } else if coordinator.segments.isEmpty {
                    Picker("Capture", selection: $coordinator.microphoneOnly) {
                        Text("My microphone and call audio").tag(false)
                        Text("My microphone only").tag(true)
                    }.pickerStyle(.segmented)
                    Picker("Microphone", selection: $microphone) {
                        Text("System default").tag("")
                        ForEach(microphones) { Text($0.name).tag($0.id) }
                        if !microphone.isEmpty && !microphones.contains(where: { $0.id == microphone }) { Text("Saved microphone · unavailable").tag(microphone) }
                    }
                    if !coordinator.microphoneOnly {
                        HStack {
                            Picker("Call audio", selection: $coordinator.selectedApp) {
                                Text("All system audio").tag("")
                                ForEach(coordinator.apps) { Text($0.name).tag($0.id) }
                                if !coordinator.selectedApp.isEmpty && !coordinator.apps.contains(where: { $0.id == coordinator.selectedApp }) {
                                    Text("Selected app · unavailable").tag(coordinator.selectedApp)
                                }
                            }
                            Button { coordinator.refreshApps(); microphones = MicrophoneDevice.available() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh call apps and microphones").accessibilityLabel("Refresh call apps and microphones")
                        }
                        Text(coordinator.selectedApp.isEmpty ? "All system audio includes other apps, music and notification sounds. Choose a call app to limit capture." : "All audio from this app is included, including other tabs if it is a browser.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if speech.working { ProgressView().controlSize(.small); Button("Cancel preparation") { speech.cancel() } }
                        else if !speech.ready { Button("Prepare speech model") { speech.prepare(allowDownload: true) } }
                        Spacer()
                        Button("Start transcription") { coordinator.begin() }.buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: .command).disabled(!speech.ready || speech.isInUse)
                    }
                    if !speech.ready { Text(speech.status).font(.caption).foregroundStyle(.secondary) }
                    Text("Let participants know before recording. Your microphone and call audio are transcribed locally; no video is captured. Sessions stop after two hours or when you close this window.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
            Divider()
            if coordinator.segments.isEmpty {
                ContentUnavailableView(coordinator.phase == .starting ? "Waiting for recording access" : (coordinator.phase.isBusy ? "Listening for speech" : "Your transcript appears here"), systemImage: "text.bubble", description: Text(coordinator.phase == .starting ? "Recording has not started. Respond to the macOS permission prompt, or cancel." : (coordinator.phase.isBusy ? "Text arrives in sections about every 20 seconds. You can stop at any time." : "Microphone and call audio are labeled separately. They are audio sources, not individual speaker names.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MeetingTranscriptBrowser(segments: coordinator.segments, onCreateTask: coordinator.createTask)
            }
            Divider()
            if let error = coordinator.historySaveIssue ?? history.errorMessage {
                HStack {
                    Text(error + " The current transcript is still available here.")
                        .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    if coordinator.historySaveIssue != nil {
                        Button("Retry history save") { coordinator.retryHistorySave() }.controlSize(.small)
                    }
                }.padding(.horizontal, 14).padding(.top, 10)
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(coordinator.isHistorySuppressedForSession ? "History skipped for this session." : (history.enabled ? "History on · 30 days on this Mac" : "Kept in memory until cleared or quit."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Library…") { MeetingHistoryController.shared.showWindow() }.controlSize(.small)
                }
                Spacer()
                if !coordinator.phase.isBusy { Button("New session…") { confirmClear = true }.disabled(coordinator.segments.isEmpty) }
                Button("Copy all") { coordinator.copy() }.disabled(coordinator.segments.isEmpty)
                Menu("Save all…") {
                    Button("Plain text…") { coordinator.save() }.keyboardShortcut("s", modifiers: .command)
                    Button("Markdown…") { coordinator.save(format: .markdown) }
                }.disabled(coordinator.segments.isEmpty)
            }.padding(14)
        }
        .alert("Clear this transcript and start a new session?", isPresented: $confirmClear) {
            Button("Clear transcript", role: .destructive) { coordinator.clear() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Save or copy this transcript first if you want to keep it. Any transcript already in your library stays there until deleted or expired.") }
        .onAppear { microphones = MicrophoneDevice.available() }
    }
    private func audioHealth(_ title: String, seconds: TimeInterval, level: Float) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) · \(seconds > 0 ? "Audio received" : "Waiting for audio")").font(.caption)
            ProgressView(value: Double(level)).accessibilityLabel("\(title) audio level")
        }.frame(maxWidth: .infinity)
    }
}

@MainActor
final class MeetingSuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init(coordinator: MeetingCoordinator) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 430, height: 180), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true; hidesOnDeactivate = false; isReleasedWhenClosed = false
        level = .statusBar; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear; isOpaque = false; hasShadow = true
        contentView = NSHostingView(rootView: MeetingSuggestionView(coordinator: coordinator))
    }
    func showWithoutActivation() {
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            setFrameOrigin(NSPoint(x: screen.frame.midX - frame.width / 2, y: screen.visibleFrame.maxY - frame.height - 12))
        }
        orderFrontRegardless()
    }
}

private struct MeetingSuggestionView: View {
    @ObservedObject var coordinator: MeetingCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Transcribe this call?", systemImage: "waveform").font(.headline)
            Text(coordinator.suggestion?.message ?? "").font(.callout)
            Text("Nothing is recorded until you choose Start.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Not now") { coordinator.dismissSuggestion() }
                Button("Snooze 1 hour") { coordinator.snooze() }
                Spacer()
                Button("Transcribe…") { coordinator.openSuggestion() }.buttonStyle(.borderedProminent)
            }.controlSize(.small)
        }.padding(18).frame(width: 430, height: 180).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
