import AVFoundation
import CEchoDSP

/// RNNoise noise suppression of one channel at 48 kHz (SPEC § 6.2, § 7). Feed samples in any amounts; the output
/// is aligned with the input (RNNoise's two-frame delay removed) and, once `finish()` is called, exactly as long.
public final class RNNoiseDenoiser {
    public static let sampleRate: Double = 48_000
    public static let frameSize = Int(EEDenoiserFrameSize)
    /// RNNoise v0.2 returns each sample two frames (20 ms) after it went in.
    static let latency = 2 * frameSize

    private let denoiser: OpaquePointer
    private var input: [Float]
    private var output: [Float]
    private var buffered = 0
    private var inputCount = 0
    private var outputCount = 0
    private var skipped = 0

    public init() throws {
        guard let denoiser = EEDenoiserCreate() else { throw RNNoiseError.unavailable }
        self.denoiser = denoiser
        input = Array(repeating: 0, count: Self.frameSize)
        output = Array(repeating: 0, count: Self.frameSize)
    }

    deinit {
        EEDenoiserDestroy(denoiser)
    }

    /// Denoises `samples` (48 kHz, −1…1) and returns the output that's ready; it trails the input by up to
    /// `latency + frameSize` samples until `finish()`.
    public func process(_ samples: UnsafeBufferPointer<Float>) -> [Float] {
        var result: [Float] = []
        result.reserveCapacity(samples.count + Self.frameSize)
        inputCount += samples.count
        var offset = 0
        while offset < samples.count {
            let count = min(Self.frameSize - buffered, samples.count - offset)
            input.withUnsafeMutableBufferPointer { frame in
                _ = UnsafeMutableBufferPointer(rebasing: frame[buffered..<(buffered + count)])
                    .initialize(from: samples[offset..<(offset + count)])
            }
            buffered += count
            offset += count
            if buffered == Self.frameSize { runFrame(appendingTo: &result) }
        }
        return result
    }

    public func process(_ samples: [Float]) -> [Float] {
        samples.withUnsafeBufferPointer { process($0) }
    }

    /// The rest of the output: pushes silence through until the output is as long as the input.
    public func finish() -> [Float] {
        var result: [Float] = []
        while outputCount < inputCount {
            input.withUnsafeMutableBufferPointer { frame in
                for index in buffered..<Self.frameSize { frame[index] = 0 }
            }
            buffered = Self.frameSize
            runFrame(appendingTo: &result)
        }
        return result
    }

    private func runFrame(appendingTo result: inout [Float]) {
        input.withUnsafeBufferPointer { frame in
            output.withUnsafeMutableBufferPointer { denoised in
                _ = EEDenoiserProcess(denoiser, denoised.baseAddress!, frame.baseAddress!)
            }
        }
        buffered = 0
        let skip = min(Self.latency - skipped, Self.frameSize)
        skipped += skip
        let count = min(Self.frameSize - skip, inputCount - outputCount)
        guard count > 0 else { return }
        result.append(contentsOf: output[skip..<(skip + count)])
        outputCount += count
    }
}

extension RNNoiseDenoiser {
    /// Denoises every channel of `buffer` on its own (SPEC § 6.2), converted to 48 kHz float first when it isn't.
    /// The result is 48 kHz float, deinterleaved, with the same channels.
    public static func denoise(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let channels = try AudioChannels.float48k(buffer).map { channel in
            let denoiser = try RNNoiseDenoiser()
            return denoiser.process(channel) + denoiser.finish()
        }
        return try AudioChannels.buffer(channels, sampleRate: sampleRate)
    }
}

public enum RNNoiseError: Error, Equatable {
    /// RNNoise couldn't be set up (out of memory).
    case unavailable
}
