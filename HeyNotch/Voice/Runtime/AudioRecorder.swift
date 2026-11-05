import AVFoundation
import AudioToolbox
import Combine
import CoreAudio

struct MicrophoneDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let audioID: AudioDeviceID

    static func available() -> [Self] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            func string(_ selector: AudioObjectPropertySelector) -> String? {
                var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                let pointer = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
                pointer.initialize(to: nil)
                defer { pointer.deinitialize(count: 1); pointer.deallocate() }
                var length = UInt32(MemoryLayout<CFString>.size)
                guard AudioObjectGetPropertyData(id, &property, 0, nil, &length, pointer) == noErr else { return nil }
                return pointer.pointee?.takeRetainedValue() as String?
            }
            guard let uid = string(kAudioDevicePropertyDeviceUID), let name = string(kAudioObjectPropertyName) else { return nil }
            return Self(id: uid, name: name, audioID: id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private final class AudioCaptureBuffer: @unchecked Sendable {
    let buffer: BoundedAudioBuffer
    let sampleRate: Double
    let channels: Int
    init(rate: Double, channels: Int, maximumDuration: TimeInterval) {
        sampleRate = rate; self.channels = channels
        buffer = BoundedAudioBuffer(sampleRate: rate, sourceChannels: channels, durationLimit: maximumDuration,
                                    bufferedSeconds: min(maximumDuration, 120))
    }
    func append(_ audio: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard audio.format.sampleRate == sampleRate, Int(audio.format.channelCount) == channels,
              let data = audio.floatChannelData else { buffer.fail(); return }
        let count = Int(audio.frameLength)
        var mono = [Float](repeating: 0, count: count)
        for frame in 0..<count {
            for channel in 0..<channels { mono[frame] += data[channel][frame] }
            mono[frame] /= Float(channels)
        }
        buffer.append(mono, atHostTime: time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil)
    }
}

@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var duration: TimeInterval = 0
    private var engine: AVAudioEngine?
    private var captured: AudioCaptureBuffer?
    private var timer: Task<Void, Never>?
    private var changed: Any?
    var onLimit: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(deviceUID: String, maximumDuration: TimeInterval = 120) throws {
        discard()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw VoiceError.microphoneDenied }
        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        if !deviceUID.isEmpty {
            guard var id = MicrophoneDevice.available().first(where: { $0.id == deviceUID })?.audioID,
                  let unit = input.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { throw VoiceError.microphoneUnavailable }
        }
        let format = input.outputFormat(forBus: 0)
        guard (8_000...192_000).contains(format.sampleRate), (1...8).contains(format.channelCount),
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { throw VoiceError.microphoneUnavailable }
        let capture = AudioCaptureBuffer(rate: format.sampleRate, channels: Int(format.channelCount), maximumDuration: maximumDuration)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, time in capture.append(buffer, at: time) }
        do { newEngine.prepare(); try newEngine.start() }
        catch { input.removeTap(onBus: 0); throw VoiceError.microphoneUnavailable }
        captured = capture; engine = newEngine; duration = 0; level = 0
        let engineID = ObjectIdentifier(newEngine)
        changed = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.engine.map(ObjectIdentifier.init) == engineID else { return }
                // Stop the device immediately, but let the consumer recover the
                // last valid chunk rather than throwing it away before notification.
                self.stopEngine(); self.onFailure?(VoiceError.deviceChanged)
            }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, let capture = self.captured else { return }
                let (level, duration, invalid) = capture.buffer.meter()
                self.level = level; self.duration = duration
                if invalid { self.stopEngine(); self.onFailure?(VoiceError.deviceChanged); return }
                if duration >= maximumDuration { self.onLimit?(); return }
            }
        }
    }

    func stop() -> RecordedAudio? {
        stopTimed()?.audio
    }

    func stopTimed() -> TimedRecordedAudio? {
        stopEngine()
        let audio = captured?.buffer.drainTimed(); captured = nil
        return audio
    }

    private func stopEngine() {
        timer?.cancel(); timer = nil
        if let changed { NotificationCenter.default.removeObserver(changed); self.changed = nil }
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop(); engine.reset() }
        engine = nil; level = 0
    }

    func drain(overlap: TimeInterval = 1) -> RecordedAudio? { captured?.buffer.drain(overlap: overlap) }
    func drainTimed(overlap: TimeInterval = 1) -> TimedRecordedAudio? { captured?.buffer.drainTimed(overlap: overlap) }

    func discard() { _ = stop() }
}
