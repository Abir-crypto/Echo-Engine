import CEchoDSP
import Foundation

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

    static func rms<C: Collection<Float>>(_ samples: C) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    static func rmsDB<C: Collection<Float>>(_ samples: C) -> Float {
        echo.dsp.linearToDb(rms(samples))
    }
}
