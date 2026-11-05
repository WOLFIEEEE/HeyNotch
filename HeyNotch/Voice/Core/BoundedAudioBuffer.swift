import Foundation

struct TimedRecordedAudio: Sendable {
    let audio: RecordedAudio
    /// Seconds on the macOS host clock, independent of wall-clock changes.
    let startedAtHostTime: TimeInterval?
}

/// A bounded, lock-protected mono buffer shared by real-time capture callbacks.
/// Draining retains one second of context, but never returns that tail twice
/// without new audio. Duration counts all captured frames, including drains.
final class BoundedAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var total = 0
    private var fresh = 0
    private var invalid = false
    private var level: Float = 0
    private var startHostTime: TimeInterval?
    private var nextHostTime: TimeInterval?
    let sampleRate: Double
    let sourceChannels: Int
    let durationLimit: TimeInterval
    private let capacity: Int

    init(sampleRate: Double, sourceChannels: Int, durationLimit: TimeInterval = 120, bufferedSeconds: TimeInterval = 120) {
        self.sampleRate = sampleRate; self.sourceChannels = sourceChannels; self.durationLimit = durationLimit
        capacity = Int(sampleRate * bufferedSeconds)
    }
    func append(_ mono: [Float], atHostTime hostTime: TimeInterval? = nil) {
        lock.lock(); defer { lock.unlock() }
        let count = min(mono.count, max(0, Int(sampleRate * durationLimit) - total))
        guard count > 0 else { return }
        guard !invalid, mono.allSatisfy(\.isFinite) else { invalid = true; return }
        if let hostTime {
            guard hostTime.isFinite, hostTime >= 0 else { invalid = true; return }
            if let nextHostTime {
                let difference = hostTime - nextHostTime
                // Capture clocks can jitter by a few frames. Large backwards
                // jumps indicate a discontinuity and must not corrupt timing.
                guard difference >= -0.05 else { invalid = true; return }
                if difference > 0.05 {
                    if fresh == 0 {
                        // Only an already-transcribed overlap remains. Do not
                        // retain it across a silent gap or allocate minutes of silence.
                        samples.removeAll(keepingCapacity: true); startHostTime = hostTime
                    } else {
                        let missing = difference * sampleRate
                        guard missing < Double(capacity), samples.count + Int(missing.rounded()) + count <= capacity else { invalid = true; return }
                        samples.append(contentsOf: repeatElement(0, count: Int(missing.rounded())))
                    }
                }
            }
            if samples.isEmpty { startHostTime = hostTime }
            nextHostTime = hostTime + Double(count) / sampleRate
        }
        guard samples.count + count <= capacity else { invalid = true; return }
        samples.append(contentsOf: mono.prefix(count)); total += count; fresh += count
        level = min(1, sqrt(mono.prefix(count).reduce(Float(0)) { $0 + $1 * $1 } / Float(count)) * 8)
    }
    func fail() { lock.lock(); invalid = true; lock.unlock() }
    func meter() -> (level: Float, duration: Double, invalid: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (level, Double(total) / sampleRate, invalid)
    }
    func drain(overlap: TimeInterval = 0) -> RecordedAudio? { drainTimed(overlap: overlap)?.audio }

    func drainTimed(overlap: TimeInterval = 0) -> TimedRecordedAudio? {
        lock.lock(); defer { lock.unlock() }
        guard fresh > 0 else { return nil }
        let result = TimedRecordedAudio(audio: RecordedAudio(monoSamples: samples, sampleRate: sampleRate, sourceChannels: sourceChannels), startedAtHostTime: startHostTime)
        let tail = max(0, min(samples.count, Int(overlap * sampleRate)))
        if let startHostTime { self.startHostTime = startHostTime + Double(samples.count - tail) / sampleRate }
        samples = Array(samples.suffix(tail)); fresh = 0
        return result
    }
}
