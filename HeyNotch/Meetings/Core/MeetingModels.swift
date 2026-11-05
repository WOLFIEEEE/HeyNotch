import Foundation

struct MeetingActivity: Equatable, Sendable {
    var microphoneApps: [MeetingApp] = []
    var cameraInUse = false
    var hasActivity: Bool { !microphoneApps.isEmpty || cameraInUse }
    var message: String {
        if let app = microphoneApps.first { return "\(app.name) is using your microphone." }
        return "Another app is using your camera."
    }
}

struct MeetingApp: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

/// Activity is a suggestion, never proof of a meeting. Input, camera and app
/// changes share one episode, so switching devices or muting does not nag.
struct MeetingSuggestionPolicy {
    var stableDelay: TimeInterval = 6
    var quietReset: TimeInterval = 120
    var cooldown: TimeInterval = 900
    private(set) var snoozedUntil: Date?
    private var began: Date?
    private var lastActivity: Date?
    private var lastPrompt: Date?
    private var handled = false

    mutating func observe(_ activity: MeetingActivity, at now: Date, enabled: Bool, busy: Bool) -> Bool {
        if let snoozedUntil, now >= snoozedUntil {
            self.snoozedUntil = nil; handled = false; began = nil; lastPrompt = nil
        }
        if let lastActivity, now.timeIntervalSince(lastActivity) >= quietReset {
            began = nil; handled = false; self.lastActivity = nil
        }
        guard activity.hasActivity else {
            if !handled { began = nil }
            return false
        }
        if began == nil { began = now }
        lastActivity = now
        guard enabled, !busy, !handled, now >= (snoozedUntil ?? .distantPast),
              now.timeIntervalSince(began ?? now) >= stableDelay,
              now.timeIntervalSince(lastPrompt ?? .distantPast) >= cooldown else { return false }
        handled = true; lastPrompt = now
        return true
    }

    mutating func dismiss() { if began != nil { handled = true } }
    mutating func snooze(at now: Date, seconds: TimeInterval = 3600) {
        snoozedUntil = now.addingTimeInterval(seconds); handled = true
    }
    mutating func resume() { snoozedUntil = nil; handled = false; lastPrompt = nil; began = nil }
    mutating func resetActivity() { began = nil; lastActivity = nil; handled = false }
}

enum MeetingPhase: String {
    case idle, starting, recording, finishing, finished
    var isBusy: Bool { [.starting, .recording, .finishing].contains(self) }
}

enum MeetingAudioSource: String, Codable, Sendable { case microphone = "Microphone", call = "Call audio" }

struct MeetingAudioChunk: Sendable {
    let source: MeetingAudioSource
    let offset: TimeInterval
    let audio: RecordedAudio
    var overlapContainsSpeech: Bool {
        offset > 0 && RecordedAudio(monoSamples: Array(audio.monoSamples.prefix(Int(audio.sampleRate))), sampleRate: audio.sampleRate, sourceChannels: audio.sourceChannels).isSpeechCandidate
    }
}

/// An explicit queue budget protects against delayed callbacks as well as a
/// slow decoder. Only normalized 16 kHz audio may enter this queue.
struct MeetingAudioQueue {
    private var chunks: [MeetingAudioChunk] = []
    private var sampleCount = 0
    let maximumChunks: Int
    let maximumSamples: Int
    init(maximumChunks: Int = 6, maximumSamples: Int = 16_000 * 150) {
        self.maximumChunks = maximumChunks; self.maximumSamples = maximumSamples
    }
    var count: Int { chunks.count }
    var isEmpty: Bool { chunks.isEmpty }
    mutating func append(_ chunk: MeetingAudioChunk) -> Bool {
        guard chunk.audio.sampleRate == 16_000, chunks.count < maximumChunks,
              chunk.audio.monoSamples.count <= maximumSamples - sampleCount else { return false }
        chunks.append(chunk); sampleCount += chunk.audio.monoSamples.count; return true
    }
    mutating func removeFirst() -> MeetingAudioChunk {
        let chunk = chunks.removeFirst(); sampleCount -= chunk.audio.monoSamples.count; return chunk
    }
    mutating func removeAll() { chunks.removeAll(); sampleCount = 0 }
}

struct MeetingTranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    let source: MeetingAudioSource
    let offset: TimeInterval
    let text: String
    var isGap = false
    var timestamp: String { Self.timestamp(offset) }
    static func timestamp(_ offset: TimeInterval) -> String {
        let value = max(0, Int(offset))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}

enum MeetingTranscript {
    static func export(_ segments: [MeetingTranscriptSegment], started: Date?, callSource: String) -> String {
        let date = started.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? ""
        let header = "HeyNotch meeting transcript\n\(date)\nCall audio: \(callSource)\nSource labels identify audio channels, not individual speakers.\n"
        return header + "\n" + segments.sorted { $0.offset < $1.offset }.map {
            "[\($0.timestamp)] \($0.source.rawValue)\($0.isGap ? " · transcription gap" : ""): \($0.text)"
        }.joined(separator: "\n\n")
    }

    /// Only remove a substantial exact overlap between adjacent chunks from
    /// the same channel; punctuation differences do not rewrite the transcript.
    static func removingOverlap(_ text: String, after previous: String?) -> String {
        guard let previous else { return text }
        let old = previous.split(whereSeparator: \.isWhitespace)
        let new = text.split(whereSeparator: \.isWhitespace)
        // A one-second overlap cannot reasonably contain dozens of words.
        // Never erase a whole new section just because a sentence was repeated.
        let maximum = min(6, old.count, new.count - 1)
        guard maximum >= 3 else { return text }
        for count in stride(from: maximum, through: 3, by: -1) {
            if old.suffix(count).map(String.init) == new.prefix(count).map(String.init) {
                return new.dropFirst(count).joined(separator: " ")
            }
        }
        return text
    }
}

enum MeetingError: Error, LocalizedError {
    case audioAccess, appUnavailable, audioFormat, backlog, captureStopped, captureStartFailed, captureConfiguration
    var errorDescription: String? {
        switch self {
        case .audioAccess: return "Allow Screen & System Audio Recording for HeyNotch in System Settings, then start again. No meeting recording has started."
        case .appUnavailable: return "The selected call app is unavailable. Select the app again or choose All system audio."
        case .audioFormat: return "The call audio format changed or could not be read. Recording stopped; the transcript is kept."
        case .backlog: return "Speech recognition could not keep up. Recording stopped to protect this Mac’s memory. The queued audio will finish transcribing."
        case .captureStopped: return "Call audio capture stopped. The transcript is kept. Check recording permission and start a new session."
        case .captureStartFailed: return "macOS could not start call audio capture. Check the selected app and audio device, then try again."
        case .captureConfiguration: return "This build could not configure system audio capture. Recording has stopped. Check the app’s signing and audio-capture configuration."
        }
    }
}
