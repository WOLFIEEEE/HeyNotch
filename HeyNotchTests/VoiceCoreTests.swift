import Foundation
import XCTest

final class VoiceCoreTests: XCTestCase {
    func testCancellationReachesDetachedDecoderCallbacksAndDeadlineIsBounded() {
        let now = Date()
        let gate = SpeechDecodeGate(deadline: now.addingTimeInterval(10))
        XCTAssertTrue(gate.allowsWork(at: now))
        XCTAssertFalse(gate.allowsWork(at: now.addingTimeInterval(10)))
        gate.cancel()
        XCTAssertFalse(gate.allowsWork(at: now))
    }
    func testSilenceAndShortClicksDoNotReachSpeechRecognition() {
        XCTAssertFalse(RecordedAudio(monoSamples: Array(repeating: 0, count: 16_000), sampleRate: 16_000, sourceChannels: 1).isSpeechCandidate)
        XCTAssertFalse(RecordedAudio(monoSamples: Array(repeating: 0.5, count: 100), sampleRate: 16_000, sourceChannels: 1).isSpeechCandidate)
        let speech = (0..<16_000).map { Float(sin(Double($0) * 0.1) * 0.1) }
        XCTAssertTrue(RecordedAudio(monoSamples: speech, sampleRate: 16_000, sourceChannels: 2).isSpeechCandidate)
    }
    func testSilenceWithinLongRecordingDoesNotPreventSpeech() {
        var samples = Array(repeating: Float(0), count: 160_000)
        for i in 32_000..<48_000 { samples[i] = Float(sin(Double(i) * 0.1) * 0.1) }
        XCTAssertTrue(RecordedAudio(monoSamples: samples, sampleRate: 16_000, sourceChannels: 1).isSpeechCandidate)
    }
    func testEmptyAndRepeatedTranscriptsAreSuppressed() {
        XCTAssertThrowsError(try SpeechTranscriptFilter.validate("  "))
        XCTAssertThrowsError(try SpeechTranscriptFilter.validate(String(repeating: "thank you ", count: 8)))
        XCTAssertNoThrow(try SpeechTranscriptFilter.validate("Thank you for joining. The meeting starts at 10:30."))
    }
    func testModelManifestRejectsTraversalAndUntrustedHosts() {
        func manifest(_ path: String, _ url: String) -> SpeechModelManifest {
            SpeechModelManifest(id: "test", name: "test", repositoryRevision: "revision", tokenizerRevision: "tokenizer", files: [
                .init(path: path, url: URL(string: url)!, sha256: String(repeating: "a", count: 64), size: 5)
            ])
        }
        XCTAssertFalse(manifest("../outside", "https://huggingface.co/file").valid)
        XCTAssertFalse(manifest("model", "http://huggingface.co/file").valid)
        XCTAssertFalse(manifest("model", "https://untrusted.example/file").valid)
        XCTAssertTrue(manifest("model/weights.bin", "https://huggingface.co/file").valid)
    }
}
