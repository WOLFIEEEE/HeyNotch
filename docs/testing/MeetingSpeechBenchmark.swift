// Compiled by run_meeting_benchmark.py with the app's actual audio buffer,
// local speech engine and transcript export code. No live capture is opened.
import AVFoundation
import Foundation

@main struct MeetingSpeechBenchmark {
    static func main() async throws {
        let args = CommandLine.arguments
        let engine = LocalSpeechEngine()
        try await engine.load(folder: URL(fileURLWithPath: args[1]))
        var segments: [MeetingTranscriptSegment] = []
        var measurements: [[String: Any]] = []
        for (index, source) in [MeetingAudioSource.microphone, .call].enumerated() {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[2 + index]))
            let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: pcm)
            let original = Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
            let clip = try LocalSpeechEngine.resample(RecordedAudio(monoSamples: original, sampleRate: pcm.format.sampleRate, sourceChannels: 1))
            var track = [Float](repeating: 0, count: 50 * 16_000)
            for start in [2, 22, 42] {
                for (offset, sample) in clip.enumerated() where start * 16_000 + offset < track.count { track[start * 16_000 + offset] = sample }
            }
            let buffer = BoundedAudioBuffer(sampleRate: 16_000, sourceChannels: 1, durationLimit: 7200, bufferedSeconds: 65)
            var previous: String?
            for start in stride(from: 0, to: track.count, by: 20 * 16_000) {
                let end = min(start + 20 * 16_000, track.count)
                // Feed small callback-sized blocks, then drain as the app does.
                for packet in stride(from: start, to: end, by: 1024) { buffer.append(Array(track[packet..<min(packet + 1024, end)])) }
                let audio = buffer.drain(overlap: 1)!
                guard !buffer.meter().invalid else { throw MeetingError.audioFormat }
                let began = Date()
                let text = try await engine.transcribe(audio, language: "en")
                let offset = Double(end) / 16_000 - audio.duration
                let chunk = MeetingAudioChunk(source: source, offset: offset, audio: audio)
                let clean = MeetingTranscript.removingOverlap(text, after: chunk.overlapContainsSpeech ? previous : nil)
                previous = text
                if !clean.isEmpty { segments.append(.init(source: source, offset: offset, text: clean)) }
                measurements.append(["source": source.rawValue, "offset": offset, "audioSeconds": audio.duration,
                                     "decodeSeconds": Date().timeIntervalSince(began), "text": text])
            }
            guard buffer.drain() == nil else { throw MeetingError.audioFormat }
        }
        await engine.unload()
        let text = MeetingTranscript.export(segments, started: Date(timeIntervalSince1970: 1_800_000_000), callSource: "Synthetic call audio")
        guard segments.count == 6,
              segments.contains(where: { $0.source == .microphone && $0.text.lowercased().contains("do not send") }),
              segments.contains(where: { $0.source == .call && $0.text.lowercased().contains("friday") }) else { throw VoiceError.invalidTranscript }
        let data = try JSONSerialization.data(withJSONObject: ["method": "Two generated 50-second channels; actual app buffer, decoder and export; no microphone or system capture",
            "runs": measurements, "transcript": text], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: args[4]))
        print("Passed: both generated channels transcribed across three chunks each.")
    }
}
