import AVFoundation
import CEchoDSP
@testable import EchoCore
import EchoCoreFakes
import Foundation
import Synchronization
import Testing

final class FinalRendererTests {
    private let directory: URL

    init() throws {
        directory = try TestMedia.makeDirectory()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ channels: [[Float]]) throws -> URL {
        let url = directory.appending(path: "input-\(UUID().uuidString).caf")
        try TestMedia.writeSamples(channels, to: url)
        return url
    }

    private func render(
        _ audio: URL,
        manual: ManualSettings = ManualSettings(),
        trim: TimeRangeCodable,
        loudness: LoudnessTarget? = nil,
        autoLevel: any AutoLevelAnalyzing = AutoLevelAnalyzer(),
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let output = directory.appending(path: "final-\(UUID().uuidString).m4a")
        let request = FinalRenderRequest(audio: audio, manual: manual, trimRange: trim, outputLoudness: loudness)
        try await FinalRenderer(autoLevel: autoLevel).render(request, to: output, progress: progress)
        return output
    }

    private func maxDifference(_ a: [Float], _ b: some Collection<Float>) -> Float {
        zip(a, b).map { abs($0 - $1) }.max() ?? .infinity
    }

    @Test func rendersOnlyTheTrimRangeIntoLosslessAudio() async throws {
        let tone = TestSignal.sine(440, amplitude: 0.1, frames: 480_000)
        let audio = try write([tone, tone.map { -$0 }])

        let output = try await render(audio, trim: TimeRangeCodable(start: 2, duration: 3))

        let file = try AVAudioFile(forReading: output)
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatAppleLossless)
        #expect(file.fileFormat.sampleRate == 48_000)
        let result = try AIProcessorTests.read(output)
        #expect(result.count == 2)
        #expect(result[0].count == 144_000)
        #expect(maxDifference(result[0], tone[96_000..<240_000]) < 1e-5, "same frames, only 24-bit rounding")
        #expect(maxDifference(result[1], tone[96_000..<240_000].map { -$0 }) < 1e-5)
    }

    @Test func theManualChainAndTheRecomputedAutoLevelGainApply() async throws {
        let tone = TestSignal.sine(440, amplitude: 0.1, frames: 240_000)
        let audio = try write([tone])
        var manual = ManualSettings()
        manual.inputGainDB = 6
        let autoLevel = FakeAutoLevelAnalyzer(gain: 6)
        let trim = TimeRangeCodable(start: 1, duration: 2)

        let output = try await render(audio, manual: manual, trim: trim, loudness: .youtube, autoLevel: autoLevel)

        let requests = await autoLevel.requests
        #expect(requests.count == 1)
        #expect(requests.first?.audio == audio)
        #expect(requests.first?.manual == manual)
        #expect(requests.first?.range == trim)
        #expect(requests.first?.target == .youtube)
        let result = try AIProcessorTests.read(output)[0]
        let gain = echo.dsp.dbToLinear(12)
        #expect(result.count == 96_000)
        #expect(maxDifference(result, tone[48_000..<144_000].map { $0 * gain }) < 1e-4)
    }

    @Test func withoutALoudnessTargetNothingIsMeasured() async throws {
        let tone = TestSignal.sine(440, amplitude: 0.1, frames: 96_000)
        let autoLevel = FakeAutoLevelAnalyzer(gain: 6)

        let output = try await render(try write([tone]), trim: .full(duration: 2), autoLevel: autoLevel)

        #expect(await autoLevel.requests.isEmpty)
        #expect(maxDifference(try AIProcessorTests.read(output)[0], tone) < 1e-5)
    }

    @Test func theExportReachesTheLoudnessTargetOverTheTrimRange() async throws {
        // A stereo 1 kHz tone's loudness equals its peak in dBFS (EBU 3341): −30 LUFS, then −10 LUFS.
        let quiet = TestSignal.sine(1_000, amplitude: Float(pow(10, -30.0 / 20)), frames: 240_000)
        let loud = TestSignal.sine(1_000, amplitude: Float(pow(10, -10.0 / 20)), frames: 240_000)
        let samples = quiet + loud
        let audio = try write([samples, samples])
        let trim = TimeRangeCodable(start: 0, duration: 5)

        let output = try await render(audio, trim: trim, loudness: .youtube)

        let measured = try await EBUR128Analyzer().measure(output, range: .full(duration: 5), progress: { _ in })
        #expect(abs(try #require(measured.integratedLUFS) - -14) < 0.15)
    }

    @Test func theLimiterHoldsTheUsersCeilingWithoutAutoLevel() async throws {
        let loud = TestSignal.speechLike(frames: 96_000).map { $0 * 3 }
        var manual = ManualSettings()
        manual.limiter.ceilingDB = -3

        let output = try await render(try write([loud]), manual: manual, trim: .full(duration: 2))

        #expect(try AVAudioFile(forReading: output).fileFormat.channelCount == 1, "mono stays mono")
        let measured = try await EBUR128Analyzer().measure(output, range: .full(duration: 2), progress: { _ in })
        #expect(measured.truePeakDBTP <= -3 + 0.2)
    }

    @Test func progressRunsOnceFromZeroToOneThroughAnalysisAndRendering() async throws {
        let audio = try write([TestSignal.sine(1_000, amplitude: 0.05, frames: 240_000)])
        let values = Mutex<[Double]>([])

        _ = try await render(audio, trim: .full(duration: 5), loudness: .podcast) { value in
            values.withLock { $0.append(value) }
        }

        let reported = values.withLock { $0 }
        #expect(reported.first == 0)
        #expect(reported.last == 1)
        #expect(zip(reported, reported.dropFirst()).allSatisfy { $0 <= $1 }, "never goes back")
    }

    @Test func cancellingLeavesNoFile() async throws {
        let audio = try write([TestSignal.sine(440, amplitude: 0.1, frames: 48_000 * 60)])
        let output = directory.appending(path: "cancelled.m4a")
        let request = FinalRenderRequest(audio: audio, manual: ManualSettings(), trimRange: .full(duration: 60), outputLoudness: nil)

        let task = Task { try await FinalRenderer(autoLevel: AutoLevelAnalyzer()).render(request, to: output, progress: { _ in }) }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: output.path()))
    }

    @Test func anUnreadableInputFailsWithoutAFile() async throws {
        let output = directory.appending(path: "never.m4a")
        let request = FinalRenderRequest(
            audio: directory.appending(path: "missing.caf"), manual: ManualSettings(), trimRange: .full(duration: 1), outputLoudness: nil
        )

        await #expect(throws: RenderError.unreadableInput) {
            try await FinalRenderer(autoLevel: AutoLevelAnalyzer()).render(request, to: output, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: output.path()))
    }
}
