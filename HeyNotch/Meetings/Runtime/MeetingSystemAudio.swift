import AVFoundation
import ScreenCaptureKit

/// Only an audio output is registered; no video frames are delivered or stored.
/// Application filters also scope audio. There is no silent fallback to capturing
/// every application if the selected call app has disappeared.
@MainActor
final class MeetingSystemAudio {
    private var stream: SCStream?
    private var output: MeetingAudioOutput?
    private var generation = UUID()
    private let queue = DispatchQueue(label: "com.wolfieeee.heynotch.meeting-audio", qos: .userInitiated)
    var onFailure: ((Error) -> Void)?

    func start(bundleID: String) async throws {
        let id = UUID(); generation = id
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
        catch { throw Self.captureError(error) }
        try Task.checkCancellation()
        guard let display = content.displays.first else { throw MeetingError.appUnavailable }
        let filter: SCContentFilter
        if bundleID.isEmpty {
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        } else {
            let matching = content.applications.filter { $0.bundleIdentifier == bundleID || $0.bundleIdentifier.hasPrefix(bundleID + ".") }
            guard !matching.isEmpty else { throw MeetingError.appUnavailable }
            filter = SCContentFilter(display: display, including: matching, exceptingWindows: [])
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true; config.excludesCurrentProcessAudio = true
        config.sampleRate = 16_000; config.channelCount = 1
        // ScreenCaptureKit requires a display filter even for audio-only output.
        config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        config.queueDepth = 3; config.showsCursor = false
        let handler = MeetingAudioOutput { [weak self] in
            Task { @MainActor in
                guard self?.generation == id else { return }
                self?.onFailure?(MeetingError.captureStopped)
            }
        }
        let capture = SCStream(filter: filter, configuration: config, delegate: handler)
        try capture.addStreamOutput(handler, type: .audio, sampleHandlerQueue: queue)
        output = handler; stream = capture
        do { try await capture.startCapture(); try Task.checkCancellation() }
        catch { await stop(); throw Self.captureError(error) }
    }

    func drain(overlap: TimeInterval = 1) throws -> RecordedAudio? {
        try drainTimed(overlap: overlap)?.audio
    }
    func drainTimed(overlap: TimeInterval = 1, recoveringValidAudio: Bool = false) throws -> TimedRecordedAudio? {
        guard let output else { return nil }
        guard recoveringValidAudio || !output.buffer.meter().invalid else { throw MeetingError.audioFormat }
        return output.buffer.drainTimed(overlap: overlap)
    }
    var health: (level: Float, duration: Double, invalid: Bool) { output?.buffer.meter() ?? (0, 0, false) }
    private static func captureError(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        let failure = error as NSError
        guard failure.domain == SCStreamErrorDomain else { return MeetingError.captureStartFailed }
        switch failure.code {
        case SCStreamError.Code.userDeclined.rawValue: return MeetingError.audioAccess
        case SCStreamError.Code.missingEntitlements.rawValue, SCStreamError.Code.invalidParameter.rawValue: return MeetingError.captureConfiguration
        case SCStreamError.Code.failedNoMatchingApplicationContext.rawValue, SCStreamError.Code.noCaptureSource.rawValue: return MeetingError.appUnavailable
        default: return MeetingError.captureStartFailed
        }
    }
    func stop() async {
        generation = UUID()
        let previous = stream; stream = nil
        try? await previous?.stopCapture()
        // Keep the buffer until the coordinator takes the final chunk.
    }
    func discard() { output = nil }
}

private final class MeetingAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let buffer = BoundedAudioBuffer(sampleRate: 16_000, sourceChannels: 1, durationLimit: 7205, bufferedSeconds: 65)
    private let failure: @Sendable () -> Void
    init(failure: @escaping @Sendable () -> Void) { self.failure = failure }
    func stream(_ stream: SCStream, didStopWithError error: Error) { failure() }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        do {
            let samples = try MeetingPCMDecoder.decode(sampleBuffer)
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard timestamp.isValid, timestamp.isNumeric else { buffer.fail(); return }
            buffer.append(samples, atHostTime: CMTimeGetSeconds(timestamp))
        }
        catch { buffer.fail() }
    }
}
