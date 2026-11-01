import AVFoundation
import CEchoDSP

/// Integrated loudness and true peak of a file range (SPEC § 4.3, § 6.7).
public protocol LoudnessAnalyzing: Sendable {
    func measure(_ audio: URL, range: TimeRangeCodable, progress: @Sendable (Double) -> Void) async throws -> LoudnessMeasurement
}

public struct LoudnessMeasurement: Equatable, Sendable {
    /// LUFS; `nil` when nothing passes the gates (silence).
    public let integratedLUFS: Double?
    /// dBTP; −infinity for digital silence.
    public let truePeakDBTP: Double

    public init(integratedLUFS: Double?, truePeakDBTP: Double) {
        self.integratedLUFS = integratedLUFS
        self.truePeakDBTP = truePeakDBTP
    }
}

public enum LoudnessError: Error, Equatable {
    case unreadable
}

/// ITU-R BS.1770-4 / EBU R128 measurement of a file (any sample rate, mono or stereo), via `LoudnessMeter` in
/// `CEchoDSP`. Reads one second at a time, reporting progress and stopping when cancelled.
public struct EBUR128Analyzer: LoudnessAnalyzing {
    public init() {}

    public func measure(_ audio: URL, range: TimeRangeCodable, progress: @Sendable (Double) -> Void) async throws -> LoudnessMeasurement {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audio)
        } catch {
            throw LoudnessError.unreadable
        }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let start = min(max(AVAudioFramePosition((range.start * sampleRate).rounded()), 0), file.length)
        let end = min(max(AVAudioFramePosition((range.end * sampleRate).rounded()), start), file.length)
        let chunkFrames = AVAudioFrameCount(sampleRate)
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw LoudnessError.unreadable
        }
        var meter = echo.dsp.LoudnessMeter()
        meter.prepare(sampleRate, Int32(format.channelCount), true)
        file.framePosition = start
        progress(0)
        while file.framePosition < end {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), end - file.framePosition))
            do {
                try file.read(into: chunk, frameCount: frames)
            } catch {
                throw LoudnessError.unreadable
            }
            guard chunk.frameLength > 0, let data = chunk.floatChannelData else { break }
            // `floatChannelData` has the layout of the meter's `const float* const*`.
            let channels = UnsafeRawPointer(data).assumingMemoryBound(to: UnsafePointer<Float>?.self)
            meter.process(channels, Int32(format.channelCount), Int32(chunk.frameLength))
            progress(Double(file.framePosition - start) / Double(max(end - start, 1)))
        }
        progress(1)
        let integrated = meter.integratedLUFS()
        return LoudnessMeasurement(integratedLUFS: integrated.isNaN ? nil : integrated, truePeakDBTP: meter.truePeakDBTP())
    }
}
