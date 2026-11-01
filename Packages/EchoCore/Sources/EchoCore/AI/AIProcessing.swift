import Foundation

/// Runs ONE AI operation on a whole file (SPEC § 4.3, § 7.2): `input` (48 kHz, any channel count) → `output`
/// (ALAC 24-bit, 48 kHz, same channels, same length). Reports progress 0…1 and stops with `CancellationError` when its
/// task is cancelled (checked between chunks, SPEC § 4.6).
public protocol AIProcessing: Sendable {
    func process(_ op: AIOperation, input: URL, output: URL, progress: @Sendable (Double) -> Void) async throws
}

public enum RenderError: Error, Equatable {
    /// The input file can't be opened or read.
    case unreadableInput
    /// The input isn't 48 kHz audio (SPEC § 6.2).
    case unsupportedFormat
    /// The output can't be written (e.g. no space left).
    case cantWrite
    /// The processor couldn't be set up.
    case processorUnavailable
}

/// Dispatches by `op.kind` (SPEC § 7.2). `.unknown` operations, and features without a processor yet, pass the input
/// through unchanged.
public struct AIProcessorRouter: AIProcessing {
    private let processors: [AIFeature: any AIProcessing]
    private let passThrough: any AIProcessing

    public init(processors: [AIFeature: any AIProcessing], passThrough: any AIProcessing = PassThroughProcessor()) {
        self.processors = processors
        self.passThrough = passThrough
    }

    public func process(_ op: AIOperation, input: URL, output: URL, progress: @Sendable (Double) -> Void) async throws {
        let processor = op.kind == .unknown ? passThrough : processors[op.kind] ?? passThrough
        try await processor.process(op, input: input, output: output, progress: progress)
    }
}

/// Copies the audio unchanged into the render format.
public struct PassThroughProcessor: AIProcessing {
    public init() {}

    public func process(_ op: AIOperation, input: URL, output: URL, progress: @Sendable (Double) -> Void) async throws {
        try await ChunkedRender.run(input: input, output: output, progress: progress) { _ in Identity() }
    }

    private struct Identity: ChunkTransform {
        func process(_ channels: [[Float]]) -> [[Float]] { channels }
        func finish() -> [[Float]] { [] }
    }
}

/// Noise Suppression (SPEC § 7): RNNoise on each channel; strength is the wet/dry mix.
public struct RNNoiseProcessor: AIProcessing {
    public init() {}

    public func process(_ op: AIOperation, input: URL, output: URL, progress: @Sendable (Double) -> Void) async throws {
        let strength = op.strength
        try await ChunkedRender.run(input: input, output: output, progress: progress) { channelCount in
            WetDryMix(wet: try DenoiseTransform(channelCount: channelCount), amount: strength, channelCount: channelCount)
        }
    }
}

/// Clear Voice (SPEC § 7): RNNoise → presence EQ (high-pass 80 Hz, −2 dB at 250 Hz, +2.5 dB shelf at 3 kHz) →
/// gentle compressor (3:1 above −20 dBFS). Strength scales the EQ, the ratio and the wet/dry mix.
public struct ClearVoiceProcessor: AIProcessing {
    public init() {}

    public func process(_ op: AIOperation, input: URL, output: URL, progress: @Sendable (Double) -> Void) async throws {
        let strength = op.strength
        try await ChunkedRender.run(input: input, output: output, progress: progress) { channelCount in
            let wet = ChainedTransform(
                first: try DenoiseTransform(channelCount: channelCount),
                second: ClearVoiceTone(channelCount: channelCount, strength: strength)
            )
            return WetDryMix(wet: wet, amount: strength, channelCount: channelCount)
        }
    }
}
