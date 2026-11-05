// Compiled only by run_speech_benchmark.py, alongside the app's actual engine.
import AVFoundation
import Foundation

@main struct SpeechBenchmark {
    static func main() async throws {
        let args = CommandLine.arguments
        let model = args[1], root = URL(fileURLWithPath: args[2])
        let engine = LocalSpeechEngine()
        let started = Date()
        try await engine.load(folder: root.appendingPathComponent(model))
        let loadSeconds = Date().timeIntervalSince(started)
        var runs: [[String: Any]] = []
        for path in args.dropFirst(3) {
            let url = URL(fileURLWithPath: path)
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { throw VoiceError.invalidAudio }
            try file.read(into: buffer)
            guard let data = buffer.floatChannelData else { throw VoiceError.invalidAudio }
            let channels = Int(format.channelCount), frames = Int(buffer.frameLength)
            var samples = [Float](repeating: 0, count: frames)
            for channel in 0..<channels { for i in 0..<frames { samples[i] += data[channel][i] / Float(channels) } }
            let audio = RecordedAudio(monoSamples: samples, sampleRate: format.sampleRate, sourceChannels: channels)
            for attempt in 1...2 {
                let start = Date()
                let text = try await engine.transcribe(audio, language: url.lastPathComponent.contains("hindi") ? "hi" : "en")
                runs.append(["sample": url.lastPathComponent, "attempt": attempt, "audioSeconds": audio.duration,
                             "recognitionSeconds": Date().timeIntervalSince(start), "transcript": text])
            }
        }
        await engine.unload()
        let data = try JSONSerialization.data(withJSONObject: ["model": model, "loadSeconds": loadSeconds, "runs": runs], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("benchmark-\(model).json"))
        print("Completed \(model) speech check.")
    }
}
