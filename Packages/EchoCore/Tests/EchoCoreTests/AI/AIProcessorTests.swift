import AVFoundation
import CEchoDSP
@testable import EchoCore
import EchoCoreFakes
import Foundation
import Synchronization
import Testing

final class AIProcessorTests {
    private let directory: URL
    private let voice: [Float]

    init() throws {
        directory = try TestMedia.makeDirectory()
        voice = try TestSignal.voice()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private var noisy: [Float] {
        zip(voice, TestSignal.fanNoise(frames: voice.count, rmsDB: -35)).map(+)
    }

    private func run(_ processor: some AIProcessing, _ kind: AIFeature, strength: Float, channels: [[Float]]) async throws -> [[Float]] {
        let input = directory.appending(path: "input-\(UUID().uuidString).caf")
        let output = directory.appending(path: "output-\(UUID().uuidString).m4a")
        try TestMedia.writeSamples(channels, to: input)
        try await processor.process(AIOperation(kind: kind, strength: strength), input: input, output: output, progress: { _ in })
        return try Self.read(output)
    }

    static func read(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let data = try #require(buffer.floatChannelData)
        return (0..<Int(buffer.format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: Int(buffer.frameLength))) }
    }

    /// Levels of `signal` in the clean voice's pauses and speech.
    private func levels(_ signal: [Float]) -> (pauses: Float, speech: Float) {
        let frames = stride(from: 0, to: voice.count - 480, by: 480).map { $0..<($0 + 480) }
        let pauses = frames.filter { TestSignal.rmsDB(voice[$0]) < -60 }
        let speech = frames.filter { TestSignal.rmsDB(voice[$0]) > -40 }
        return (TestSignal.rmsDB(pauses.flatMap { signal[$0] }), TestSignal.rmsDB(speech.flatMap { signal[$0] }))
    }

    // MARK: Noise Suppression

    @Test func noiseSuppressionWritesALACAndRemovesTheFan() async throws {
        let input = directory.appending(path: "in.caf")
        let output = directory.appending(path: "out.m4a")
        try TestMedia.writeSamples([noisy], to: input)

        try await RNNoiseProcessor().process(AIOperation(kind: .noiseSuppression, strength: 1), input: input, output: output) { _ in }

        let file = try AVAudioFile(forReading: output)
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatAppleLossless)
        #expect(file.fileFormat.sampleRate == 48_000)
        let result = try Self.read(output)[0]
        #expect(result.count == voice.count)
        #expect(levels(result).pauses < levels(noisy).pauses - 15)
        #expect(abs(levels(result).speech - levels(voice).speech) < 3)
    }

    @Test func strengthZeroLeavesTheAudio() async throws {
        let result = try await run(RNNoiseProcessor(), .noiseSuppression, strength: 0, channels: [noisy])[0]
        #expect(zip(result, noisy).map { abs($0 - $1) }.max()! < 1e-5, "only 24-bit rounding")
    }

    @Test func halfStrengthIsHalfway() async throws {
        let result = try await run(RNNoiseProcessor(), .noiseSuppression, strength: 0.5, channels: [noisy])[0]
        // Between words the denoised part is near silence, so half of the input remains: −6 dB.
        #expect(abs(levels(result).pauses - (levels(noisy).pauses - 6)) < 1.5)
    }

    @Test func eachChannelIsProcessedOnItsOwn() async throws {
        let silence = [Float](repeating: 0, count: voice.count)
        let result = try await run(RNNoiseProcessor(), .noiseSuppression, strength: 1, channels: [noisy, silence])
        #expect(result.count == 2)
        #expect(result[1].map(abs).max()! < 1e-5)
    }

    @Test func progressRisesToOne() async throws {
        let input = directory.appending(path: "in.caf")
        try TestMedia.writeSamples([noisy], to: input)
        let log = Mutex<[Double]>([])

        try await RNNoiseProcessor().process(
            AIOperation(kind: .noiseSuppression, strength: 1), input: input, output: directory.appending(path: "out.m4a")
        ) { value in log.withLock { $0.append(value) } }

        let values = log.withLock { $0 }
        #expect(values.first == 0)
        #expect(values.last == 1)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values.count > 5, "per one-second chunk")
    }

    @Test func cancellingStopsAndLeavesNoFile() async throws {
        let input = directory.appending(path: "long.caf")
        let output = directory.appending(path: "out.m4a")
        try TestMedia.writeSamples([TestSignal.fanNoise(frames: 48_000 * 30, rmsDB: -30)], to: input)

        let task = Task {
            try await RNNoiseProcessor().process(AIOperation(kind: .noiseSuppression, strength: 1), input: input, output: output) { _ in }
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func otherSampleRatesAndUnreadableFilesAreRefused() async throws {
        let wrongRate = directory.appending(path: "44k.caf")
        try TestMedia.writeSamples([[0, 0.1, 0.2]], to: wrongRate, sampleRate: 44_100)
        let garbage = directory.appending(path: "garbage.caf")
        try Data("not audio".utf8).write(to: garbage)
        let op = AIOperation(kind: .noiseSuppression, strength: 1)

        await #expect(throws: RenderError.unsupportedFormat) {
            try await RNNoiseProcessor().process(op, input: wrongRate, output: self.directory.appending(path: "a.m4a")) { _ in }
        }
        await #expect(throws: RenderError.unreadableInput) {
            try await RNNoiseProcessor().process(op, input: garbage, output: self.directory.appending(path: "b.m4a")) { _ in }
        }
    }

    // MARK: Clear Voice

    @Test func clearVoiceIsBrighterThanNoiseSuppressionAlone() async throws {
        let clear = try await run(ClearVoiceProcessor(), .clearVoice, strength: 1, channels: [noisy])[0]
        let suppressed = try await run(RNNoiseProcessor(), .noiseSuppression, strength: 1, channels: [noisy])[0]

        func presence(_ signal: [Float]) -> Float {
            var state = echo.dsp.BiquadState()
            let filter = echo.dsp.makeBiquad(.highPass, 48_000, 3_000, 0, 0.707)
            let highs = signal.map { state.process(filter, $0, 0) }
            return TestSignal.rmsDB(highs) - TestSignal.rmsDB(signal)
        }
        #expect(presence(clear) > presence(suppressed) + 1)
        #expect(levels(clear).pauses < levels(noisy).pauses - 15, "noise suppression comes first")
    }

    @Test func clearVoiceEvensOutLoudness() async throws {
        let quiet = try await run(ClearVoiceProcessor(), .clearVoice, strength: 1, channels: [voice.map { $0 * 0.5 }])[0]
        let loud = try await run(ClearVoiceProcessor(), .clearVoice, strength: 1, channels: [voice])[0]
        // 6 dB louder in; the 3:1 compressor above −20 dBFS lets through clearly less.
        #expect(levels(loud).speech - levels(quiet).speech < 4.5)
    }

    @Test func clearVoiceRemovesRumble() async throws {
        let rumble = (0..<voice.count).map { 0.1 * Float(sin(2 * .pi * 40 * Double($0) / 48_000)) }
        let result = try await run(ClearVoiceProcessor(), .clearVoice, strength: 1, channels: [zip(voice, rumble).map(+)])[0]

        func at40Hz(_ signal: [Float]) -> Float {
            var state = echo.dsp.BiquadState()
            let filter = echo.dsp.makeBiquad(.lowPass, 48_000, 60, 0, 0.707)
            return TestSignal.rmsDB(signal.map { state.process(filter, $0, 0) })
        }
        #expect(at40Hz(result) < at40Hz(rumble) - 10)
    }

    @Test func clearVoiceAtZeroStrengthLeavesTheAudio() async throws {
        let result = try await run(ClearVoiceProcessor(), .clearVoice, strength: 0, channels: [noisy])[0]
        #expect(zip(result, noisy).map { abs($0 - $1) }.max()! < 1e-5)
    }

    // MARK: Router

    @Test func theRouterDispatchesByKind() async throws {
        let fake = FakeAIProcessor()
        let router = AIProcessorRouter(processors: [.noiseSuppression: fake])
        _ = try await run(router, .noiseSuppression, strength: 0.7, channels: [noisy])
        #expect(await fake.processed.map(\.kind) == [.noiseSuppression])
    }

    @Test(arguments: [AIFeature.unknown, .voiceLeveler])
    func unknownAndUnavailableFeaturesPassThrough(_ kind: AIFeature) async throws {
        let fake = FakeAIProcessor()
        let router = AIProcessorRouter(processors: [.noiseSuppression: fake, .clearVoice: fake])
        let result = try await run(router, kind, strength: 1, channels: [noisy])[0]
        #expect(zip(result, noisy).map { abs($0 - $1) }.max()! < 1e-5)
        #expect(await fake.processed.isEmpty)
    }
}
