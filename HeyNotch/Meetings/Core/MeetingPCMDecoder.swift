import AVFoundation

enum MeetingPCMDecoder {
    /// The stream explicitly requests mono Float32 PCM at 16 kHz. Reject a
    /// changed layout rather than interpreting arbitrary bytes as samples.
    static func decode(_ sampleBuffer: CMSampleBuffer) throws -> [Float] {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate == 16_000,
              format.mChannelsPerFrame == 1, format.mBitsPerChannel == 32,
              format.mBytesPerFrame == 4, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { throw MeetingError.audioFormat }
        var block: CMBlockBuffer?
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil))
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: &list, bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &block)
        guard status == noErr, list.mNumberBuffers == 1, let data = list.mBuffers.mData else { throw MeetingError.audioFormat }
        let count = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard count == CMSampleBufferGetNumSamples(sampleBuffer) else { throw MeetingError.audioFormat }
        let samples = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        guard samples.allSatisfy(\.isFinite) else { throw MeetingError.audioFormat }
        return samples
    }
}
