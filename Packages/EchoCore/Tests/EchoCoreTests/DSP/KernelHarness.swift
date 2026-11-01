import AVFoundation
import CEchoDSP
import Foundation
import Testing

/// Non-interleaved float channels in the layout the kernels' `process(float* const*, channels, frames)` expects.
/// Pointer storage is allocated up front, so processing through it never allocates.
final class ChannelBuffers {
    let channelCount: Int
    let frameCount: Int
    private let channels: [UnsafeMutablePointer<Float>]
    /// Pointers to the current block's first frame, one per channel.
    private let block: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    init(_ input: [[Float]]) {
        channelCount = input.count
        frameCount = input.first?.count ?? 0
        channels = input.map { samples in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
            pointer.initialize(from: samples, count: samples.count)
            return pointer
        }
        block = .allocate(capacity: max(1, input.count))
        block.initialize(repeating: nil, count: max(1, input.count))
    }

    deinit {
        channels.forEach { $0.deallocate() }
        block.deallocate()
    }

    /// Channel pointers starting at `frame`.
    func pointers(at frame: Int) -> UnsafeMutablePointer<UnsafeMutablePointer<Float>?> {
        for index in 0..<channelCount {
            block[index] = channels[index] + frame
        }
        return block
    }

    var output: [[Float]] {
        channels.map { Array(UnsafeBufferPointer(start: $0, count: frameCount)) }
    }

    /// Calls `body` per block of up to `blockSize` frames, like a render callback.
    func processBlocks(
        of blockSize: Int = 512,
        _ body: (_ channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>, _ frames: Int32, _ start: Int) -> Void
    ) {
        var start = 0
        while start < frameCount {
            let frames = min(blockSize, frameCount - start)
            body(pointers(at: start), Int32(frames), start)
            start += frames
        }
    }

    func processBlocks(
        of blockSize: Int = 512,
        _ body: (_ channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>, _ frames: Int32) -> Void
    ) {
        processBlocks(of: blockSize) { channels, frames, _ in body(channels, frames) }
    }
}

enum TestSignal {
    static let sampleRate: Double = 48_000

    /// Deterministic speech-like test input (0.25 s by default): 220/660 Hz voice pulsing at 4 Hz, a 7 kHz sibilant
    /// burst at 0.15–0.2 s, and low noise. Peaks just above 0 dBFS, so the limiter works too.
    static func speechLike(frames: Int = 12_000) -> [Float] {
        var seed: UInt32 = 0x1234_5678
        return (0..<frames).map { frame in
            let time = Double(frame) / sampleRate
            let envelope = 0.5 + 0.5 * sin(2 * .pi * 4 * time)
            let voice = 0.6 * sin(2 * .pi * 220 * time) + 0.2 * sin(2 * .pi * 660 * time)
            let sibilance = time > 0.15 && time < 0.2 ? 0.3 * sin(2 * .pi * 7_000 * time) : 0
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = (Double(seed >> 8) / Double(1 << 24) - 0.5) * 0.02
            return Float(envelope * voice + sibilance + noise)
        }
    }

    static func sine(_ frequency: Double, amplitude: Float, frames: Int) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    /// A vowel-like voice: a pulse train at `f0` through two formant resonators (700 Hz and 1.2 kHz), peaking at 0.5.
    static func vowel(f0: Double, frames: Int, formants: [Double] = [700, 1_200]) -> [Float] {
        let period = Int((sampleRate / f0).rounded())
        var resonators = formants.map { (echo.dsp.makeBiquad(.bandPass, sampleRate, $0, 0, 5), echo.dsp.BiquadState()) }
        let raw = (0..<frames).map { frame -> Float in
            let pulse: Float = frame % period == 0 ? 1 : 0
            var output: Float = 0
            for index in resonators.indices {
                output += resonators[index].1.process(resonators[index].0, pulse, 0)
            }
            return output
        }
        let peak = raw.map(abs).max() ?? 1
        return raw.map { $0 * 0.5 / peak }
    }

    /// A voice with irregular pulse spacing (260–380 samples), so delays can be measured without a period's
    /// ambiguity. Peaks at 0.5.
    static func irregularVoice(frames: Int, seed: UInt32 = 7) -> [Float] {
        var seed = seed
        var pulses = [Float](repeating: 0, count: frames)
        var position = 0
        while position < frames {
            pulses[position] = 1
            seed = seed &* 1_664_525 &+ 1_013_904_223
            position += 260 + Int(seed >> 24) % 120
        }
        var resonators = [700.0, 1_200.0].map { (echo.dsp.makeBiquad(.bandPass, sampleRate, $0, 0, 5), echo.dsp.BiquadState()) }
        let raw = pulses.map { pulse -> Float in
            var output: Float = 0
            for index in resonators.indices {
                output += resonators[index].1.process(resonators[index].0, pulse, 0)
            }
            return output
        }
        let peak = raw.map(abs).max() ?? 1
        return raw.map { $0 * 0.5 / peak }
    }

    /// Deterministic fan noise at `rmsDB`: low rumble, a 180 Hz blade tone with two harmonics, and soft hiss
    /// (SPEC § 19 "fan", generated).
    static func fanNoise(frames: Int, rmsDB: Float) -> [Float] {
        var seed: UInt32 = 0xFA_0001
        var rumble: Float = 0
        let raw = (0..<frames).map { frame -> Float in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let white = Float(seed >> 8) / Float(1 << 23) - 1
            rumble += (white - rumble) * 0.05
            let time = Double(frame) / sampleRate
            let blade = (0.5 * sin(2 * .pi * 180 * time) + 0.25 * sin(2 * .pi * 360 * time) + 0.12 * sin(2 * .pi * 540 * time))
                * (1 + 0.1 * sin(2 * .pi * 0.7 * time))
            return 4 * rumble + 0.1 * white + Float(blade) * 0.3
        }
        let scale = echo.dsp.dbToLinear(rmsDB) / rms(raw)
        return raw.map { $0 * scale }
    }

    /// `Resources/TestAudio/voice.caf`: 6 s of generated speech, 48 kHz mono.
    static func voice() throws -> [Float] {
        let url = try #require(Bundle.module.url(forResource: "voice", withExtension: "caf", subdirectory: "Resources/TestAudio"))
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
    }

    /// Deterministic white noise in −amplitude…amplitude.
    static func noise(amplitude: Float, frames: Int) -> [Float] {
        var seed: UInt32 = 0xC0FF_EE11
        return (0..<frames).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return amplitude * (Float(seed >> 8) / Float(1 << 23) - 1)
        }
    }

    /// The pitch `PitchDetector` finds at the end of `samples`, in Hz; `nil` when unvoiced.
    static func detectedFrequency(_ samples: [Float]) -> Double? {
        var detector = echo.dsp.PitchDetector()
        detector.prepare(sampleRate)
        samples.forEach { detector.push($0) }
        let estimate = detector.detect()
        return estimate.period > 0 ? sampleRate / Double(estimate.period) : nil
    }

    /// Power-weighted mean frequency between `low` and `high` (Hann-windowed Goertzel bins), to compare spectral
    /// envelopes.
    static func spectralCentroid(_ samples: [Float], from low: Double = 200, to high: Double = 4_000, step: Double = 10) -> Double {
        let count = samples.count
        let windowed = samples.enumerated().map { index, sample in
            Double(sample) * (0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(count - 1)))
        }
        var weighted = 0.0, total = 0.0
        for frequency in stride(from: low, through: high, by: step) {
            let coefficient = 2 * cos(2 * .pi * frequency / sampleRate)
            var previous = 0.0, beforePrevious = 0.0
            for sample in windowed {
                let current = sample + coefficient * previous - beforePrevious
                beforePrevious = previous
                previous = current
            }
            let power = previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
            weighted += frequency * power
            total += power
        }
        return weighted / total
    }

    /// Lag (in −range…range) at which `output` best matches `input`.
    static func bestLag(of output: [Float], against input: [Float], in range: ClosedRange<Int>, over frames: Range<Int>) -> Int {
        var best = (lag: 0, score: -Float.infinity)
        for lag in range {
            var score: Float = 0
            for index in frames where index + lag >= 0 && index + lag < output.count {
                score += input[index] * output[index + lag]
            }
            if score > best.score { best = (lag, score) }
        }
        return best.lag
    }

    static func rms<C: Collection<Float>>(_ samples: C) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    static func rmsDB<C: Collection<Float>>(_ samples: C) -> Float {
        echo.dsp.linearToDb(rms(samples))
    }
}

/// Reference outputs in `Resources/TestAudio/Golden/<name>.f32` (raw little-endian Float32 mono). Re-record after an
/// intended DSP change with `ECHO_UPDATE_GOLDEN=1 swift test`.
enum GoldenFile {
    /// SPEC § 19: the RMS of the difference stays below −50 dB (relative to the reference).
    static let toleranceDB: Float = -50

    static var isUpdating: Bool { ProcessInfo.processInfo.environment["ECHO_UPDATE_GOLDEN"] == "1" }

    /// The difference to the reference in dB relative to it; records `output` instead when updating (then `nil`).
    static func differenceDB(of output: [Float], name: String) throws -> Float? {
        if isUpdating {
            try write(output, to: sourceURL(name))
            return nil
        }
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "f32", subdirectory: "Resources/TestAudio/Golden"),
            "No golden file for \(name); record it with ECHO_UPDATE_GOLDEN=1"
        )
        let reference = try read(url)
        try #require(reference.count == output.count)
        let difference = zip(output, reference).map { $0 - $1 }
        return TestSignal.rmsDB(difference) - TestSignal.rmsDB(reference)
    }

    private static func sourceURL(_ name: String, file: String = #filePath) -> URL {
        URL(filePath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/TestAudio/Golden/\(name).f32")
    }

    private static func write(_ samples: [Float], to url: URL) throws {
        let data = samples.map(\.bitPattern.littleEndian).withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: url, options: .atomic)
    }

    private static func read(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        return stride(from: 0, to: data.count - 3, by: 4).map { offset in
            let bits = data[data.startIndex + offset..<data.startIndex + offset + 4]
                .enumerated()
                .reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            return Float(bitPattern: bits)
        }
    }
}
