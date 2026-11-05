import AVFoundation
import XCTest

final class MeetingPCMTests: XCTestCase {
    private func sample(_ samples: [Float], rate: Double = 16_000, channels: AVAudioChannelCount = 1) throws -> CMSampleBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        pcm.frameLength = pcm.frameCapacity
        for channel in 0..<Int(channels) {
            samples.withUnsafeBufferPointer { pcm.floatChannelData![channel].update(from: $0.baseAddress!, count: samples.count) }
        }
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description), noErr)
        var result: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: description, sampleCount: samples.count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result), noErr)
        let buffer = try XCTUnwrap(result)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(buffer), noErr)
        return buffer
    }
    func testCaptureSampleDecoderPreservesMonoFloatSamples() throws {
        let expected = (0..<3200).map { Float(sin(Double($0) * 0.01) * 0.2) }
        XCTAssertEqual(try MeetingPCMDecoder.decode(sample(expected)), expected)
    }
    func testCaptureFormatChangesAreRejectedBeforeReadingBytes() throws {
        XCTAssertThrowsError(try MeetingPCMDecoder.decode(sample([0, 0.5, -0.5], rate: 48_000)))
        XCTAssertThrowsError(try MeetingPCMDecoder.decode(sample([0, 0.5, -0.5], channels: 2)))
    }
    func testNonFiniteCaptureSamplesAreRejected() throws {
        XCTAssertThrowsError(try MeetingPCMDecoder.decode(sample([0, .infinity, 0.5])))
    }
}
