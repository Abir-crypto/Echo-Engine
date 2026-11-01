import AVFoundation
import Foundation

/// Voice Leveler (SPEC § 7, § 7.1): rides the gain so every speaker sits near −20 dBFS. Two passes: measure the
/// level of every 50 ms window, then apply the smoothed gain curve and a soft limiter at −1 dBFS. Strength scales the
/// curve's depth. Channels share one gain, so the stereo image stays put.
public struct VoiceLevelerProcessor: AIProcessing {
    public init() {}

    public func process(_ op: AIOperation, input: URL, output: URL, progress: @Sendable (Double) -> Void) async throws {
        let levels = try VoiceLevelerCurve.windowLevels(of: input) { progress($0 * VoiceLevelerCurve.analysisShare) }
        let gains = VoiceLevelerCurve.gains(windowRMS: levels, strength: op.strength)
        let share = VoiceLevelerCurve.analysisShare
        try await ChunkedRender.run(input: input, output: output, progress: { progress(share + (1 - share) * $0) }) { _ in
            LevelerTransform(gainsDB: gains, windowFrames: VoiceLevelerCurve.windowFrames)
        }
    }
}

/// The leveler's gain curve, one value per 50 ms window (SPEC § 7.1).
///
/// A window is speech when its RMS is above twice the noise floor (the 10th percentile of all windows); speech gets the
/// gain that brings it to −20 dBFS (±12 dB at most), silence gets none. Smoothing: within speech the gain follows the
/// mean of the speech coming up within 300 ms (look-ahead), so louder speech is turned down in time; it falls at once
/// and rises with a 500 ms release. A phrase starts at its level right away, and silences are never boosted.
/// Following the mean (not the loudest syllable) keeps a speaker's own dynamics and centres them on −20 dBFS.
enum VoiceLevelerCurve {
    static let sampleRate: Double = 48_000
    static let windowFrames = 2_400
    static let targetDB: Float = -20
    static let maximumGainDB: Float = 12
    static let lookaheadWindows = 6     // 300 ms
    static let releaseSeconds = 0.5
    /// The analysis pass's part of the progress bar.
    static let analysisShare = 0.3

    /// RMS of every 50 ms window over all channels (linked).
    static func windowLevels(of input: URL, progress: (Double) -> Void) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: input)
        } catch {
            throw RenderError.unreadableInput
        }
        let format = file.processingFormat
        guard format.sampleRate == sampleRate, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(windowFrames * 20)) else {
            throw RenderError.unsupportedFormat
        }
        let channels = Int(format.channelCount)
        var levels: [Float] = []
        var sum: Float = 0
        var count = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            do {
                try file.read(into: chunk)
            } catch {
                throw RenderError.unreadableInput
            }
            guard chunk.frameLength > 0, let data = chunk.floatChannelData else { break }
            for frame in 0..<Int(chunk.frameLength) {
                for channel in 0..<channels {
                    sum += data[channel][frame] * data[channel][frame]
                }
                count += 1
                if count == windowFrames {
                    levels.append((sum / Float(count * channels)).squareRoot())
                    sum = 0
                    count = 0
                }
            }
            progress(Double(file.framePosition) / Double(max(file.length, 1)))
        }
        if count > 0 { levels.append((sum / Float(count * channels)).squareRoot()) }
        return levels
    }

    /// The applied gain in dB per window.
    static func gains(windowRMS: [Float], strength: Float) -> [Float] {
        guard !windowRMS.isEmpty else { return [] }
        let sorted = windowRMS.sorted()
        let noiseFloor = sorted[(sorted.count - 1) / 10]
        let depth = min(max(strength, 0), 1)
        let targets: [Float?] = windowRMS.map { rms in
            guard rms > noiseFloor * 2, rms > 0 else { return nil }
            return min(max(targetDB - 20 * log10(rms), -maximumGainDB), maximumGainDB) * depth
        }
        return smooth(targets)
    }

    /// `targets` holds each speech window's gain, `nil` for silence.
    static func smooth(_ targets: [Float?]) -> [Float] {
        let release = Float(1 - exp(-Double(windowFrames) / sampleRate / releaseSeconds))
        var result: [Float] = []
        result.reserveCapacity(targets.count)
        var current: Float?
        for index in targets.indices {
            guard targets[index] != nil else {
                result.append(0)
                current = nil
                continue
            }
            // The mean gain of the speech coming up within the look-ahead.
            let ahead = targets[index...min(index + lookaheadWindows, targets.count - 1)].compactMap { $0 }
            let upcoming = ahead.reduce(0, +) / Float(ahead.count)
            if let previous = current, upcoming > previous {
                current = previous + (upcoming - previous) * release
            } else {
                current = upcoming
            }
            result.append(current!)
        }
        return result
    }

    /// Soft limiter: linear up to −3 dBFS, then bends smoothly towards −1 dBFS without reaching it.
    static func softLimit(_ sample: Float) -> Float {
        let threshold: Float = 0.708, ceiling: Float = 0.891
        let magnitude = abs(sample)
        guard magnitude > threshold else { return sample }
        let range = ceiling - threshold
        return copysign(threshold + range * tanh((magnitude - threshold) / range), sample)
    }
}

/// Applies the window gains, interpolated between window centres. Boosted samples go through the soft limiter; the rest
/// are left as they are, so untouched peaks keep their shape.
struct LevelerTransform: ChunkTransform {
    private let gains: [Float]
    private let windowFrames: Int
    private var position = 0

    init(gainsDB: [Float], windowFrames: Int) {
        gains = gainsDB.map { powf(10, $0 / 20) }
        self.windowFrames = windowFrames
    }

    mutating func process(_ channels: [[Float]]) -> [[Float]] {
        guard let frames = channels.first?.count, !gains.isEmpty else { return channels }
        var output = channels
        for frame in 0..<frames {
            let gain = gain(at: position + frame)
            for channel in output.indices {
                let sample = output[channel][frame] * gain
                output[channel][frame] = gain > 1 ? VoiceLevelerCurve.softLimit(sample) : sample
            }
        }
        position += frames
        return output
    }

    func finish() -> [[Float]] { [] }

    private func gain(at frame: Int) -> Float {
        let place = (Double(frame) - Double(windowFrames) / 2) / Double(windowFrames)
        let lower = Int(place.rounded(.down))
        guard lower >= 0 else { return gains[0] }
        guard lower + 1 < gains.count else { return gains[gains.count - 1] }
        let fraction = Float(place - Double(lower))
        return gains[lower] + (gains[lower + 1] - gains[lower]) * fraction
    }
}
