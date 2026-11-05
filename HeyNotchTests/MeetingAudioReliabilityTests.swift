import Foundation
import XCTest

final class MeetingAudioReliabilityTests: XCTestCase {
    func testTimestampSurvivesDrainAndOverlap() throws {
        let buffer = BoundedAudioBuffer(sampleRate: 10, sourceChannels: 1, durationLimit: 100, bufferedSeconds: 10)
        buffer.append(Array(repeating: 0.1, count: 30), atHostTime: 100)
        let first = try XCTUnwrap(buffer.drainTimed(overlap: 1))
        XCTAssertEqual(first.startedAtHostTime, 100)
        XCTAssertEqual(first.audio.duration, 3)
        buffer.append(Array(repeating: 0.2, count: 20), atHostTime: 103)
        let next = try XCTUnwrap(buffer.drainTimed(overlap: 1))
        XCTAssertEqual(next.startedAtHostTime, 102)
        XCTAssertEqual(next.audio.duration, 3)
    }
    func testMissingSilentPacketsDoNotCollapseChronology() throws {
        let buffer = BoundedAudioBuffer(sampleRate: 10, sourceChannels: 1, durationLimit: 100, bufferedSeconds: 10)
        buffer.append(Array(repeating: 0.1, count: 10), atHostTime: 100)
        buffer.append(Array(repeating: 0.2, count: 10), atHostTime: 103)
        let chunk = try XCTUnwrap(buffer.drainTimed())
        XCTAssertEqual(chunk.startedAtHostTime, 100)
        XCTAssertEqual(chunk.audio.duration, 4)
        XCTAssertEqual(Array(chunk.audio.monoSamples[10..<30]), Array(repeating: 0, count: 20))
    }
    func testLongSilenceAfterDrainDoesNotAllocateSilenceOrRepeatOldContext() throws {
        let buffer = BoundedAudioBuffer(sampleRate: 10, sourceChannels: 1, durationLimit: 100, bufferedSeconds: 10)
        buffer.append(Array(repeating: 0.1, count: 20), atHostTime: 100)
        _ = buffer.drainTimed(overlap: 1)
        buffer.append(Array(repeating: 0.2, count: 20), atHostTime: 1000)
        let chunk = try XCTUnwrap(buffer.drainTimed())
        XCTAssertFalse(buffer.meter().invalid)
        XCTAssertEqual(chunk.startedAtHostTime, 1000)
        XCTAssertEqual(chunk.audio.monoSamples, Array(repeating: 0.2, count: 20))
    }
    func testBadTimestampAndOverflowPreserveEarlierValidAudioForRecovery() throws {
        for timestamp in [99.0, 200.0, Double.nan] {
            let buffer = BoundedAudioBuffer(sampleRate: 10, sourceChannels: 1, durationLimit: 100, bufferedSeconds: 3)
            buffer.append(Array(repeating: 0.1, count: 20), atHostTime: 100)
            buffer.append([0.2], atHostTime: timestamp)
            XCTAssertTrue(buffer.meter().invalid)
            let recovered = try XCTUnwrap(buffer.drainTimed())
            XCTAssertEqual(recovered.startedAtHostTime, 100)
            XCTAssertEqual(recovered.audio.monoSamples, Array(repeating: 0.1, count: 20))
        }
    }
    func testBufferDoesNotAcceptNewAudioAfterFailure() {
        let buffer = BoundedAudioBuffer(sampleRate: 10, sourceChannels: 1)
        buffer.append([0.1]); buffer.fail(); buffer.append([0.2])
        XCTAssertEqual(buffer.drain()?.monoSamples, [0.1])
    }
    private func chunk(samples: Int, offset: Double = 0, rate: Double = 16_000) -> MeetingAudioChunk {
        .init(source: .call, offset: offset, audio: RecordedAudio(monoSamples: Array(repeating: 0.1, count: samples), sampleRate: rate, sourceChannels: 1))
    }
    func testQueueEnforcesBothCountAndSampleBudgetWithoutDiscardingExistingChunks() {
        var queue = MeetingAudioQueue(maximumChunks: 2, maximumSamples: 15)
        XCTAssertTrue(queue.append(chunk(samples: 10, offset: 1)))
        XCTAssertFalse(queue.append(chunk(samples: 6)))
        XCTAssertTrue(queue.append(chunk(samples: 5, offset: 2)))
        XCTAssertFalse(queue.append(chunk(samples: 0)))
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.removeFirst().offset, 1)
        XCTAssertTrue(queue.append(chunk(samples: 10, offset: 3)))
        XCTAssertEqual(queue.removeFirst().offset, 2)
        XCTAssertEqual(queue.removeFirst().offset, 3)
        XCTAssertTrue(queue.isEmpty)
    }
    func testQueueRejectsUnnormalizedAudioAndReleasesBudgetWhenCleared() {
        var queue = MeetingAudioQueue(maximumChunks: 1, maximumSamples: 10)
        XCTAssertFalse(queue.append(chunk(samples: 5, rate: 48_000)))
        XCTAssertTrue(queue.append(chunk(samples: 10)))
        queue.removeAll()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertTrue(queue.append(chunk(samples: 10)))
    }
}
