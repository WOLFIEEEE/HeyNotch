import AVFoundation
import ArgmaxCore
import WhisperKit

actor LocalSpeechEngine {
    private var kit: WhisperKit?

    func load(folder: URL) async throws {
        await kit?.unloadModels()
        kit = nil
        // Validate the pinned local tokenizer before WhisperKit can attempt a Hub fallback.
        _ = try await AutoTokenizerWrapper.from(modelFolder: folder)
        try Task.checkCancellation()
        let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: folder,
                                      verbose: false, logLevel: .none, prewarm: false, load: false, download: false)
        #if arch(x86_64)
        config.computeOptions = ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndGPU)
        #endif
        let engine = try await WhisperKit(config)
        try await engine.loadModels()
        try Task.checkCancellation()
        kit = engine
    }

    func unload() async {
        await kit?.unloadModels()
        kit = nil
    }

    func transcribe(_ audio: RecordedAudio, language: String?) async throws -> String {
        guard let kit else { throw VoiceError.notReady }
        guard audio.isSpeechCandidate else { throw VoiceError.silence }
        let samples = try Self.resample(audio)
        let options = DecodingOptions(verbose: false, task: .transcribe, language: language,
                                      temperature: 0, temperatureFallbackCount: 1,
                                      detectLanguage: language == nil, skipSpecialTokens: true,
                                      withoutTimestamps: true, suppressBlank: true,
                                      concurrentWorkerCount: 1)
        let deadline = Date().addingTimeInterval(90)
        let gate = SpeechDecodeGate(deadline: deadline)
        return try await withTaskCancellationHandler {
            for attempt in 0..<2 {
                try Task.checkCancellation()
                let result = try await kit.transcribe(audioArray: samples, decodeOptions: options, callback: { _ in gate.allowsWork() })
                try Task.checkCancellation()
                guard Date() < deadline else { throw VoiceError.transcriptionTimeout }
                let text = result.map(\.text).joined(separator: " ")
                // A cold decoder can return an empty first pass. One local retry
                // is safe: no text has been sent to a provider or another app.
                if attempt == 0 && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                return try SpeechTranscriptFilter.validate(text)
            }
            throw VoiceError.invalidTranscript
        } onCancel: { gate.cancel() }
    }

    static func resample(_ audio: RecordedAudio) throws -> [Float] {
        guard audio.sampleRate.isFinite, (8_000...192_000).contains(audio.sampleRate),
              audio.duration <= 121, !audio.monoSamples.isEmpty else { throw VoiceError.invalidAudio }
        if audio.sampleRate == 16_000 { return audio.monoSamples }
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: audio.sampleRate, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(audio.monoSamples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(audio.duration * 16_000) + 1024)) else { throw VoiceError.invalidAudio }
        input.frameLength = input.frameCapacity
        audio.monoSamples.withUnsafeBufferPointer { pointer in
            input.floatChannelData![0].update(from: pointer.baseAddress!, count: pointer.count)
        }
        let supply = PCMBufferSupply(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            guard let buffer = supply.take() else { state.pointee = .endOfStream; return nil }
            state.pointee = .haveData; return buffer
        }
        guard status != .error, error == nil, let data = output.floatChannelData else { throw VoiceError.invalidAudio }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}

/// AVAudioConverter may request input through a Sendable callback. The PCM buffer
/// is immutable after construction and its one-time delivery is lock protected.
private final class PCMBufferSupply: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        lock.lock(); defer { lock.unlock() }
        defer { buffer = nil }
        return buffer
    }
}
