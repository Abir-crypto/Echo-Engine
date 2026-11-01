import Accelerate
import AVFoundation

/// Reads an audio file in chunks and computes its base-level peaks.
enum WaveformPeaksGenerator {
    /// A multiple of `WaveformPeaks.framesPerBucket`.
    static let chunkFrames: AVAudioFrameCount = 65_536

    static func generate(from url: URL, progress: (Double) -> Void) async throws -> WaveformPeaks {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = file.length
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw WaveformError.unreadable
        }
        let bucket = WaveformPeaks.framesPerBucket
        var peaks: [Float] = []
        peaks.reserveCapacity(Int(totalFrames) / bucket + 1)

        while file.framePosition < totalFrames {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: chunkFrames)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            for start in stride(from: 0, to: frames, by: bucket) {
                let length = vDSP_Length(min(bucket, frames - start))
                var peak: Float = 0
                for channel in 0..<Int(format.channelCount) {
                    var channelPeak: Float = 0
                    vDSP_maxmgv(channels[channel] + start, 1, &channelPeak, length)
                    peak = max(peak, channelPeak)
                }
                peaks.append(peak)
            }
            progress(Double(file.framePosition) / Double(max(totalFrames, 1)))
            await Task.yield()
        }
        return WaveformPeaks(sampleRate: format.sampleRate, sourceFrameCount: totalFrames, peaks: peaks)
    }
}
