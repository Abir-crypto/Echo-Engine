import AVFoundation

/// "Save vocal with backing track" (SPEC § 13.6): the vocal take moved earlier by the recording's round-trip latency (so
/// it lines up with what the singer heard) plus the backing track from where the take began, at its recording volume,
/// as long as the vocal. 48 kHz 32-bit float CAF, stereo if either is. No limiting: the editor's chain has the limiter.
enum TakeMixer {
    static func mix(
        vocal vocalURL: URL, backing backingURL: URL, startSeconds: Double, latencySeconds: Double, volume: Double, to output: URL
    ) throws {
        let rate = RecordingConfiguration.sampleRate
        let vocal = try AVAudioFile(forReading: vocalURL)
        let backing = try AVAudioFile(forReading: backingURL)
        let vocalChannels = Int(vocal.processingFormat.channelCount)
        let backingChannels = min(2, Int(backing.processingFormat.channelCount))
        let channels = max(vocalChannels, backingChannels)
        guard vocal.processingFormat.sampleRate == rate,
              let backingFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(backing.processingFormat.channelCount)),
              let vocalBuffer = AVAudioPCMBuffer(pcmFormat: vocal.processingFormat, frameCapacity: 48_000) else {
            throw RecordingError.cantCreateProject
        }
        let writer = try CAFWriter(url: output, sampleRate: rate, channelCount: channels)

        // The voice reached the take this much after the backing frame it answered.
        let shift = AVAudioFramePosition((latencySeconds * rate).rounded())
        vocal.framePosition = min(shift, vocal.length)
        backing.framePosition = min(AVAudioFramePosition(startSeconds * backing.processingFormat.sampleRate), backing.length)
        let reader = try ChunkReader(source: backing, outputFormat: backingFormat)
        var queued = [[Float]](repeating: [], count: backingChannels)

        var remaining = Int(vocal.length)
        var mixed = [[Float]](repeating: [], count: channels)
        while remaining > 0 {
            let count = min(48_000, remaining)
            var vocalCount = 0
            if vocal.framePosition < vocal.length {
                try vocal.read(into: vocalBuffer, frameCount: AVAudioFrameCount(min(count, Int(vocal.length - vocal.framePosition))))
                vocalCount = Int(vocalBuffer.frameLength)
            }
            while queued.first.map({ $0.count < count }) ?? false, let chunk = try reader.next() {
                for channel in 0..<backingChannels {
                    queued[channel] += UnsafeBufferPointer(start: chunk.floatChannelData![channel], count: Int(chunk.frameLength))
                }
            }
            for channel in 0..<channels {
                var samples = [Float](repeating: 0, count: count)
                if vocalCount > 0 {
                    let source = vocalBuffer.floatChannelData![min(channel, vocalChannels - 1)]
                    for frame in 0..<vocalCount { samples[frame] = source[frame] }
                }
                let backingChannel = min(channel, backingChannels - 1)
                let available = min(count, queued[backingChannel].count)
                for frame in 0..<available { samples[frame] += Float(volume) * queued[backingChannel][frame] }
                mixed[channel] = samples
            }
            for channel in 0..<backingChannels {
                queued[channel].removeFirst(min(count, queued[channel].count))
            }
            try mixed.withUnsafeBufferPointers { pointers in
                try writer.append(pointers, frames: count)
            }
            remaining -= count
        }
        try writer.close()
    }
}

private extension Array where Element == [Float] {
    /// Pointers to every channel's samples, for `CAFWriter.append`.
    func withUnsafeBufferPointers<Result>(_ body: ([UnsafePointer<Float>]) throws -> Result) rethrows -> Result {
        var pointers: [UnsafePointer<Float>] = []
        func next(_ index: Int) throws -> Result {
            guard index < count else { return try body(pointers) }
            return try self[index].withUnsafeBufferPointer { buffer in
                pointers.append(buffer.baseAddress!)
                return try next(index + 1)
            }
        }
        return try next(0)
    }
}
