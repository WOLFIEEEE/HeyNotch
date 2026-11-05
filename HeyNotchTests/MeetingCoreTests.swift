import Foundation
import XCTest

final class MeetingCoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let mic = MeetingActivity(microphoneApps: [.init(id: "us.zoom.xos", name: "Zoom")])
    private let quiet = MeetingActivity()
    private let camera = MeetingActivity(cameraInUse: true)

    func testStableInputPromptsOnceAndDoesNotRequireCamera() {
        var policy = MeetingSuggestionPolicy()
        XCTAssertFalse(policy.observe(mic, at: now, enabled: true, busy: false))
        XCTAssertFalse(policy.observe(mic, at: now.addingTimeInterval(5), enabled: true, busy: false))
        XCTAssertTrue(policy.observe(mic, at: now.addingTimeInterval(6), enabled: true, busy: false))
        XCTAssertFalse(policy.observe(mic, at: now.addingTimeInterval(60), enabled: true, busy: false))
    }
    func testBriefDeviceActivityDoesNotPrompt() {
        var policy = MeetingSuggestionPolicy()
        XCTAssertFalse(policy.observe(mic, at: now, enabled: true, busy: false))
        XCTAssertFalse(policy.observe(quiet, at: now.addingTimeInterval(2), enabled: true, busy: false))
        XCTAssertFalse(policy.observe(quiet, at: now.addingTimeInterval(8), enabled: true, busy: false))
        XCTAssertFalse(policy.observe(mic, at: now.addingTimeInterval(10), enabled: true, busy: false))
        XCTAssertFalse(policy.observe(mic, at: now.addingTimeInterval(14), enabled: true, busy: false))
    }
    func testCameraAlonePromptsWithoutInventingAnAppOrProvenMeeting() {
        var policy = MeetingSuggestionPolicy()
        _ = policy.observe(camera, at: now, enabled: true, busy: false)
        XCTAssertTrue(policy.observe(camera, at: now.addingTimeInterval(6), enabled: true, busy: false))
        XCTAssertEqual(camera.message, "Another app is using your camera.")
    }
    func testMuteAndSwitchingToCameraDoNotCreateAnotherPrompt() {
        var policy = MeetingSuggestionPolicy()
        _ = policy.observe(mic, at: now, enabled: true, busy: false)
        XCTAssertTrue(policy.observe(mic, at: now.addingTimeInterval(6), enabled: true, busy: false))
        _ = policy.observe(quiet, at: now.addingTimeInterval(60), enabled: true, busy: false)
        XCTAssertFalse(policy.observe(camera, at: now.addingTimeInterval(100), enabled: true, busy: false))
    }
    func testNewCallRequiresQuietPeriodAndCooldown() {
        var policy = MeetingSuggestionPolicy()
        _ = policy.observe(mic, at: now, enabled: true, busy: false)
        _ = policy.observe(mic, at: now.addingTimeInterval(6), enabled: true, busy: false)
        _ = policy.observe(quiet, at: now.addingTimeInterval(130), enabled: true, busy: false)
        XCTAssertFalse(policy.observe(mic, at: now.addingTimeInterval(140), enabled: true, busy: false))
        XCTAssertFalse(policy.observe(mic, at: now.addingTimeInterval(146), enabled: true, busy: false))
        _ = policy.observe(quiet, at: now.addingTimeInterval(1000), enabled: true, busy: false)
        XCTAssertFalse(policy.observe(mic, at: now.addingTimeInterval(1002), enabled: true, busy: false))
        XCTAssertTrue(policy.observe(mic, at: now.addingTimeInterval(1008), enabled: true, busy: false))
    }
    func testBusyDictationDefersPromptWithoutConsumingIt() {
        var policy = MeetingSuggestionPolicy()
        _ = policy.observe(mic, at: now, enabled: true, busy: true)
        XCTAssertFalse(policy.observe(mic, at: now.addingTimeInterval(6), enabled: true, busy: true))
        XCTAssertTrue(policy.observe(mic, at: now.addingTimeInterval(8), enabled: true, busy: false))
    }
    func testDisabledDetectionNeverPrompts() {
        var policy = MeetingSuggestionPolicy()
        _ = policy.observe(mic, at: now, enabled: false, busy: false)
        XCTAssertFalse(policy.observe(camera, at: now.addingTimeInterval(60), enabled: false, busy: false))
    }
    func testSnoozeSurvivesActivityChangesUntilExplicitResume() {
        var policy = MeetingSuggestionPolicy()
        policy.snooze(at: now)
        _ = policy.observe(mic, at: now.addingTimeInterval(10), enabled: true, busy: false)
        XCTAssertFalse(policy.observe(mic, at: now.addingTimeInterval(20), enabled: true, busy: false))
        policy.resume()
        _ = policy.observe(camera, at: now.addingTimeInterval(21), enabled: true, busy: false)
        XCTAssertTrue(policy.observe(camera, at: now.addingTimeInterval(27), enabled: true, busy: false))
    }
    func testDismissedSessionStaysDismissed() {
        var policy = MeetingSuggestionPolicy()
        _ = policy.observe(mic, at: now, enabled: true, busy: false)
        policy.dismiss()
        XCTAssertFalse(policy.observe(mic, at: now.addingTimeInterval(6), enabled: true, busy: false))
    }
    func testDismissingPreviewWithoutActivityDoesNotSuppressTheNextCall() {
        var policy = MeetingSuggestionPolicy()
        policy.dismiss()
        _ = policy.observe(mic, at: now, enabled: true, busy: false)
        XCTAssertTrue(policy.observe(mic, at: now.addingTimeInterval(6), enabled: true, busy: false))
    }
    func testSnoozeExpiresForAnOngoingCallAndDebouncesAgain() {
        var policy = MeetingSuggestionPolicy()
        policy.snooze(at: now)
        _ = policy.observe(mic, at: now.addingTimeInterval(3599), enabled: true, busy: false)
        XCTAssertFalse(policy.observe(mic, at: now.addingTimeInterval(3600), enabled: true, busy: false))
        XCTAssertTrue(policy.observe(mic, at: now.addingTimeInterval(3606), enabled: true, busy: false))
    }
    func testSilenceDoesNotProduceCallActivity() {
        XCTAssertFalse(quiet.hasActivity)
        var policy = MeetingSuggestionPolicy()
        XCTAssertFalse(policy.observe(quiet, at: now, enabled: true, busy: false))
        XCTAssertFalse(policy.observe(quiet, at: now.addingTimeInterval(100), enabled: true, busy: false))
    }
    func testBoundedAudioDrainsRetainContextWithoutDuplicatingFinalTail() {
        let buffer = BoundedAudioBuffer(sampleRate: 10, sourceChannels: 1, durationLimit: 100, bufferedSeconds: 5)
        buffer.append(Array(repeating: 0.1, count: 30))
        XCTAssertEqual(buffer.drain(overlap: 1)?.monoSamples.count, 30)
        XCTAssertNil(buffer.drain(overlap: 1))
        buffer.append(Array(repeating: 0.2, count: 20))
        let next = buffer.drain(overlap: 1)
        XCTAssertEqual(next?.monoSamples.count, 30)
        XCTAssertEqual(next?.monoSamples.prefix(10), Array(repeating: Float(0.1), count: 10)[...])
        XCTAssertEqual(buffer.meter().duration, 5)
    }
    func testAudioMemoryOverflowIsReportedInsteadOfGrowingOrSilentlyDropping() {
        let buffer = BoundedAudioBuffer(sampleRate: 10, sourceChannels: 1, bufferedSeconds: 1)
        buffer.append(Array(repeating: 0.1, count: 11))
        XCTAssertTrue(buffer.meter().invalid)
        XCTAssertNil(buffer.drain())
    }
    func testInvalidAudioIsRejectedAndTotalDurationLimitSurvivesDrains() {
        let buffer = BoundedAudioBuffer(sampleRate: 10, sourceChannels: 1, durationLimit: 2, bufferedSeconds: 2)
        buffer.append(Array(repeating: 0.1, count: 15)); _ = buffer.drain()
        buffer.append(Array(repeating: 0.1, count: 15))
        XCTAssertEqual(buffer.drain()?.monoSamples.count, 5)
        XCTAssertEqual(buffer.meter().duration, 2)
        let invalid = BoundedAudioBuffer(sampleRate: 10, sourceChannels: 1)
        invalid.append([.nan]); XCTAssertTrue(invalid.meter().invalid)
    }
    func testTranscriptOverlapOnlyRemovesExactSubstantialBoundaryMatch() {
        XCTAssertEqual(MeetingTranscript.removingOverlap("discuss the plan next week", after: "We should discuss the plan"), "next week")
        XCTAssertEqual(MeetingTranscript.removingOverlap("thank you everyone", after: "thank you"), "thank you everyone")
        XCTAssertEqual(MeetingTranscript.removingOverlap("do not send the invoice", after: "send the invoice"), "do not send the invoice")
        XCTAssertEqual(MeetingTranscript.removingOverlap("Please bring the notes", after: "Please bring the notes"), "Please bring the notes")
    }
    func testSilentOverlapDoesNotRemoveLegitimateRepeatedSentences() {
        let quietAudio = RecordedAudio(monoSamples: Array(repeating: 0, count: 32_000), sampleRate: 16_000, sourceChannels: 1)
        XCTAssertFalse(MeetingAudioChunk(source: .call, offset: 19, audio: quietAudio).overlapContainsSpeech)
        let audible = RecordedAudio(monoSamples: Array(repeating: 0.1, count: 32_000), sampleRate: 16_000, sourceChannels: 1)
        XCTAssertTrue(MeetingAudioChunk(source: .call, offset: 19, audio: audible).overlapContainsSpeech)
        XCTAssertFalse(MeetingAudioChunk(source: .call, offset: 0, audio: audible).overlapContainsSpeech)
    }
    func testExportKeepsChronologyChannelsUnicodeAndExplicitGaps() {
        let segments = [
            MeetingTranscriptSegment(source: .call, offset: 61, text: "नमस्ते 👋"),
            MeetingTranscriptSegment(source: .microphone, offset: 1, text: "Do not send the invoice."),
            MeetingTranscriptSegment(source: .call, offset: 90, text: "Audio could not be transcribed.", isGap: true)
        ]
        let text = MeetingTranscript.export(segments, started: now, callSource: "Zoom")
        XCTAssertTrue(text.contains("[00:00:01] Microphone: Do not send the invoice."))
        XCTAssertTrue(text.contains("[00:01:01] Call audio: नमस्ते 👋"))
        XCTAssertTrue(text.contains("transcription gap"))
        XCTAssertLessThan(text.range(of: "invoice")!.lowerBound, text.range(of: "नमस्ते")!.lowerBound)
        XCTAssertEqual(MeetingTranscriptSegment.timestamp(3661), "01:01:01")
    }
}
