import Foundation

struct RecordedAudio: Sendable {
    let monoSamples: [Float]
    let sampleRate: Double
    let sourceChannels: Int
    var duration: TimeInterval { Double(monoSamples.count) / sampleRate }
    var isSpeechCandidate: Bool {
        guard sampleRate > 0, duration >= 0.25, !monoSamples.isEmpty else { return false }
        // Require at least 120 ms of audible frames; silence must never reach the decoder.
        let size = max(1, Int(sampleRate * 0.02))
        var audible = 0
        for start in stride(from: 0, to: monoSamples.count, by: size) {
            let end = min(start + size, monoSamples.count)
            let power = monoSamples[start..<end].reduce(Float(0)) { $0 + $1 * $1 } / Float(end - start)
            if power > 0.000_004 { audible += 1 }
        }
        return audible >= 6
    }
}

enum VoiceMode: String, Sendable { case dictation, task }
enum VoicePhase: String, Sendable {
    case idle, preparing, recording, transcribing, processing, inserting, review, finished
    var isBusy: Bool { [.preparing, .recording, .transcribing, .processing, .inserting].contains(self) }
}

struct SpeechModelManifest: Codable, Identifiable, Sendable {
    struct File: Codable, Sendable {
        let path: String
        let url: URL
        let sha256: String
        let size: Int64
    }
    let id: String
    let name: String
    let repositoryRevision: String
    let tokenizerRevision: String
    let files: [File]
    var byteCount: Int64 { files.reduce(0) { $0 + $1.size } }
    var valid: Bool {
        !files.isEmpty && files.allSatisfy { file in
            !file.path.hasPrefix("/") && !file.path.split(separator: "/").contains("..") &&
            file.url.scheme == "https" && file.url.host == "huggingface.co" &&
            file.sha256.count == 64 && file.size > 0
        }
    }
}

enum VoiceError: Error, LocalizedError {
    case microphoneDenied, microphoneUnavailable, deviceChanged, notReady, silence, invalidAudio, invalidTranscript
    case modelDownload, modelIntegrity, insufficientDisk, transcriptionTimeout
    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "Allow microphone access for HeyNotch in System Settings, then try again."
        case .microphoneUnavailable: return "The selected microphone is unavailable. Choose an input in Voice settings."
        case .deviceChanged: return "The microphone changed. Recording stopped; start again with the current input."
        case .notReady: return "Prepare a speech model in Voice settings. Wait for Ready before speaking."
        case .silence: return "No clear speech was detected. Nothing was inserted."
        case .invalidAudio: return "This recording could not be read. Try again."
        case .invalidTranscript: return "The speech result was empty or repetitive. Nothing was inserted."
        case .modelDownload: return "The model download did not finish. Retry to keep using files already verified."
        case .modelIntegrity: return "A model file failed verification. Retry to replace it."
        case .insufficientDisk: return "There is not enough free space for this speech model. Free some space and retry."
        case .transcriptionTimeout: return "Transcription took too long. Please try a shorter recording."
        }
    }
}

enum SpeechTranscriptFilter {
    static func validate(_ text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 65_536 else { throw VoiceError.invalidTranscript }
        let words = value.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        if words.count >= 12 {
            for size in 1...min(8, words.count / 4) {
                let suffix = Array(words.suffix(size))
                if (1...4).allSatisfy({ Array(words.suffix(size * $0).prefix(size)) == suffix }) { throw VoiceError.invalidTranscript }
            }
        }
        return value
    }
}

/// WhisperKit invokes progress callbacks in detached tasks. Cancellation must
/// cross that boundary explicitly; checking Task.isCancelled inside it is not enough.
final class SpeechDecodeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let deadline: Date
    init(deadline: Date) { self.deadline = deadline }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func allowsWork(at now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !cancelled && now < deadline
    }
}
