import AVFoundation
import CEchoDSP

/// Processing of one chunk of channels at a time. It may hold samples back (latency) and return them from `finish`;
/// in total it returns exactly as many frames per channel as it was given.
protocol ChunkTransform {
    mutating func process(_ channels: [[Float]]) throws -> [[Float]]
    mutating func finish() throws -> [[Float]]
}

/// Streams a 48 kHz file through a `ChunkTransform` into an ALAC 24-bit render (SPEC § 6.2), one second at a time,
/// reporting progress and checking cancellation between chunks (SPEC § 4.6). A failed or cancelled render leaves no
/// output file behind.
enum ChunkedRender {
    static let sampleRate: Double = 48_000
    static let chunkFrames: AVAudioFrameCount = 48_000

    static func run<Transform: ChunkTransform>(
        input: URL,
        output: URL,
        progress: @Sendable (Double) -> Void,
        makeTransform: (_ channelCount: Int) throws -> Transform
    ) async throws {
        do {
            try render(input: input, output: output, progress: progress, makeTransform: makeTransform)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func render<Transform: ChunkTransform>(
        input: URL,
        output: URL,
        progress: @Sendable (Double) -> Void,
        makeTransform: (_ channelCount: Int) throws -> Transform
    ) throws {
        let source: AVAudioFile
        do {
            source = try AVAudioFile(forReading: input)
        } catch {
            throw RenderError.unreadableInput
        }
        let format = source.processingFormat
        guard format.sampleRate == sampleRate, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw RenderError.unsupportedFormat
        }
        let channelCount = Int(format.channelCount)
        var transform: Transform
        do {
            transform = try makeTransform(channelCount)
        } catch {
            throw RenderError.processorUnavailable
        }
        let destination = try makeOutput(output, channelCount: channelCount)
        guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw RenderError.unsupportedFormat
        }
        let total = max(source.length, 1)
        progress(0)
        while source.framePosition < source.length {
            try Task.checkCancellation()
            do {
                try source.read(into: chunk, frameCount: chunkFrames)
            } catch {
                throw RenderError.unreadableInput
            }
            guard chunk.frameLength > 0, let data = chunk.floatChannelData else { break }
            let channels = (0..<channelCount).map { Array(UnsafeBufferPointer(start: data[$0], count: Int(chunk.frameLength))) }
            try write(transform.process(channels), to: destination)
            progress(Double(source.framePosition) / Double(total))
        }
        try Task.checkCancellation()
        try write(transform.finish(), to: destination)
        progress(1)
    }

    private static func makeOutput(_ url: URL, channelCount: Int) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitDepthHintKey: 24,
        ]
        do {
            return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw RenderError.cantWrite
        }
    }

    private static func write(_ channels: [[Float]], to file: AVAudioFile) throws {
        guard let frames = channels.first?.count, frames > 0 else { return }
        do {
            try file.write(from: AudioChannels.buffer(channels, sampleRate: sampleRate))
        } catch {
            throw RenderError.cantWrite
        }
    }
}

/// RNNoise on every channel (each on its own, SPEC § 6.2).
final class DenoiseTransform: ChunkTransform {
    private let denoisers: [RNNoiseDenoiser]

    init(channelCount: Int) throws {
        denoisers = try (0..<channelCount).map { _ in try RNNoiseDenoiser() }
    }

    func process(_ channels: [[Float]]) -> [[Float]] {
        zip(denoisers, channels).map { $0.process($1) }
    }

    func finish() -> [[Float]] {
        denoisers.map { $0.finish() }
    }
}

/// `first`, then `second` on its output.
struct ChainedTransform<First: ChunkTransform, Second: ChunkTransform>: ChunkTransform {
    var first: First
    var second: Second

    mutating func process(_ channels: [[Float]]) throws -> [[Float]] {
        try second.process(first.process(channels))
    }

    mutating func finish() throws -> [[Float]] {
        let rest = try second.process(first.finish())
        let tail = try second.finish()
        return zip(rest, tail).map { $0 + $1 }
    }
}

/// Blends `wet` into the input by `amount` (strength, SPEC § 7). The dry input waits for the wet output, so the
/// two stay aligned whatever `wet` holds back.
struct WetDryMix<Wet: ChunkTransform>: ChunkTransform {
    var wet: Wet
    let amount: Float
    private var dry: [[Float]]

    init(wet: Wet, amount: Float, channelCount: Int) {
        self.wet = wet
        self.amount = min(max(amount, 0), 1)
        dry = Array(repeating: [], count: channelCount)
    }

    mutating func process(_ channels: [[Float]]) throws -> [[Float]] {
        for index in dry.indices { dry[index] += channels[index] }
        return mix(try wet.process(channels))
    }

    mutating func finish() throws -> [[Float]] {
        mix(try wet.finish())
    }

    private mutating func mix(_ wetChannels: [[Float]]) -> [[Float]] {
        wetChannels.enumerated().map { index, wetSamples in
            let drySamples = dry[index].prefix(wetSamples.count)
            dry[index].removeFirst(drySamples.count)
            return zip(drySamples, wetSamples).map { dry, wet in dry + (wet - dry) * amount }
        }
    }
}

/// Clear Voice's tone and dynamics after RNNoise: high-pass 80 Hz, −2 dB at 250 Hz, +2.5 dB shelf at 3 kHz, then a
/// compressor (3:1 above −20 dBFS, linked channels). Strength scales the EQ gains and the ratio.
final class ClearVoiceTone: ChunkTransform {
    private let filters: [echo.dsp.BiquadCoefficients]
    private var states: [echo.dsp.BiquadState]
    private var compressor = echo.dsp.CompressorKernel()
    private let channelCount: Int

    init(channelCount: Int, strength: Float) {
        let amount = Double(min(max(strength, 0), 1))
        let rate = ChunkedRender.sampleRate
        filters = [
            echo.dsp.makeBiquad(.highPass, rate, 80, 0, 0.707),
            echo.dsp.makeBiquad(.peaking, rate, 250, -2 * amount, 1),
            echo.dsp.makeBiquad(.highShelf, rate, 3_000, 2.5 * amount, 0.707),
        ]
        states = filters.map { _ in echo.dsp.BiquadState() }
        self.channelCount = min(channelCount, Int(echo.dsp.kMaxChannels))
        // Set before `prepare`, so nothing ramps.
        compressor.setEnabled(true)
        compressor.setThresholdDB(-20)
        compressor.setRatio(Float(1 + 2 * amount))
        compressor.prepare(rate)
    }

    func process(_ channels: [[Float]]) -> [[Float]] {
        var output = channels
        for channel in 0..<min(output.count, channelCount) {
            for frame in output[channel].indices {
                var sample = output[channel][frame]
                for index in filters.indices {
                    sample = states[index].process(filters[index], sample, Int32(channel))
                }
                output[channel][frame] = sample
            }
        }
        compress(&output)
        return output
    }

    func finish() -> [[Float]] {
        Array(repeating: [], count: channelCount)
    }

    private func compress(_ channels: inout [[Float]]) {
        guard let frames = channels.first?.count, frames > 0 else { return }
        let count = min(channels.count, channelCount)
        let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: count)
        defer { pointers.deallocate() }
        let storage = channels.prefix(count).map { samples -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            pointer.initialize(from: samples, count: frames)
            return pointer
        }
        defer { storage.forEach { $0.deallocate() } }
        for index in 0..<count { pointers[index] = storage[index] }
        compressor.process(pointers, Int32(count), Int32(frames))
        for index in 0..<count {
            channels[index] = Array(UnsafeBufferPointer(start: storage[index], count: frames))
        }
    }
}
