import AVFoundation

/// The peak levels (0…1) a Home card draws as bars (SPEC § 5.1, `waveform-overview.json`), read from an audio file.
/// Import computes the same levels while extracting; recorded projects read them from `working.caf`.
enum WaveformOverview {
    static func levels(of url: URL, count: Int = AVMediaImporter.overviewBucketCount) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let length = max(1, file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var levels = [Float](repeating: 0, count: count)
        var position: AVAudioFramePosition = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = buffer.floatChannelData![channel]
                for frame in 0..<Int(buffer.frameLength) {
                    let bucket = min(count - 1, Int((position + AVAudioFramePosition(frame)) * AVAudioFramePosition(count) / length))
                    levels[bucket] = max(levels[bucket], min(1, abs(samples[frame])))
                }
            }
            position += AVAudioFramePosition(buffer.frameLength)
        }
        return levels
    }
}
