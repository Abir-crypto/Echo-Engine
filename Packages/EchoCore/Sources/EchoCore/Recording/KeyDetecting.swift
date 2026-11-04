import Accelerate
import AVFoundation

/// A musical key: a tonic (0 C … 11 B) and major or minor.
public struct MusicalKey: Equatable, Sendable {
    public let tonic: Int
    public let scale: AutoTuneSettings.Scale

    public init(tonic: Int, scale: AutoTuneSettings.Scale) {
        self.tonic = tonic
        self.scale = scale
    }
}

/// The key of a backing track (SPEC § 4.3, § 13.5), for auto-tune's "Song key: A minor. Use it?".
public protocol KeyDetecting: Sendable {
    /// nil when the music doesn't point clearly at one key.
    func detectKey(of url: URL) async throws -> MusicalKey?
}

/// Chroma key detection: the audio's energy per pitch class (FFT, 80 Hz–2 kHz, the first two minutes), correlated with
/// the Krumhansl–Kessler major and minor key profiles in all 12 keys; the best wins if it is clear enough.
public struct ChromaKeyDetector: KeyDetecting {
    static let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
    /// Below this correlation the music isn't tonal enough to name a key.
    static let minimumCorrelation: Float = 0.6

    private let maximumSeconds: Double

    public init(maximumSeconds: Double = 120) {
        self.maximumSeconds = maximumSeconds
    }

    public func detectKey(of url: URL) async throws -> MusicalKey? {
        let chroma = try Self.chroma(of: url, maximumSeconds: maximumSeconds)
        return Self.key(for: chroma)
    }

    /// The key whose profile correlates best with `chroma` (12 pitch-class energies from C), if clear enough.
    static func key(for chroma: [Float]) -> MusicalKey? {
        guard chroma.count == 12, chroma.contains(where: { $0 > 0 }) else { return nil }
        var best: (key: MusicalKey, correlation: Float)?
        for tonic in 0..<12 {
            for (scale, profile) in [(AutoTuneSettings.Scale.major, majorProfile), (.minor, minorProfile)] {
                // The profile rotated so its tonic sits on `tonic`.
                let rotated = (0..<12).map { profile[(($0 - tonic) % 12 + 12) % 12] }
                let correlation = pearson(chroma, rotated)
                if correlation > best?.correlation ?? -.infinity { best = (MusicalKey(tonic: tonic, scale: scale), correlation) }
            }
        }
        guard let best, best.correlation >= minimumCorrelation else { return nil }
        return best.key
    }

    static func pearson(_ a: [Float], _ b: [Float]) -> Float {
        let meanA = vDSP.mean(a), meanB = vDSP.mean(b)
        let da = vDSP.add(-meanA, a), db = vDSP.add(-meanB, b)
        let denominator = (vDSP.sumOfSquares(da) * vDSP.sumOfSquares(db)).squareRoot()
        return denominator > 0 ? vDSP.dot(da, db) / denominator : 0
    }

    /// Energy per pitch class (C first) over the file's start, mono.
    static func chroma(of url: URL, maximumSeconds: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let log2n = 14
        let size = 1 << log2n, hop = size / 2
        guard let fft = vDSP.FFT(log2n: vDSP_Length(log2n), radix: .radix2, ofType: DSPSplitComplex.self),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(hop)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        // The pitch class of every FFT bin from 80 Hz to 2 kHz.
        let bins = (1..<(size / 2)).compactMap { bin -> (Int, Int)? in
            let frequency = Double(bin) * rate / Double(size)
            guard frequency >= 80, frequency <= 2_000 else { return nil }
            let midi = Int((69 + 12 * log2(frequency / 440)).rounded())
            return (bin, ((midi % 12) + 12) % 12)
        }

        var samples = [Float](repeating: 0, count: size)
        var chroma = [Float](repeating: 0, count: 12)
        var real = [Float](repeating: 0, count: size / 2), imaginary = [Float](repeating: 0, count: size / 2)
        var magnitudes = [Float](repeating: 0, count: size / 2)
        let limit = AVAudioFramePosition(maximumSeconds * rate)
        while file.framePosition < min(file.length, limit) {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(hop))
            let count = Int(buffer.frameLength)
            guard count > 0 else { break }
            // Slide the analysis window by a hop: the old half moves down, the new mono samples come in.
            samples.replaceSubrange(0..<(size - hop), with: samples[hop...])
            let channels = Int(buffer.format.channelCount)
            for frame in 0..<hop {
                var mono: Float = 0
                if frame < count {
                    for channel in 0..<channels { mono += buffer.floatChannelData![channel][frame] }
                    mono /= Float(channels)
                }
                samples[size - hop + frame] = mono
            }
            let windowed = vDSP.multiply(samples, window)
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    windowed.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { complex in
                            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(size / 2))
                        }
                    }
                    fft.forward(input: split, output: &split)
                    magnitudes.withUnsafeMutableBufferPointer { output in
                        vDSP_zvabs(&split, 1, output.baseAddress!, 1, vDSP_Length(size / 2))
                    }
                }
            }
            for (bin, pitchClass) in bins { chroma[pitchClass] += magnitudes[bin] }
        }
        return chroma
    }
}
