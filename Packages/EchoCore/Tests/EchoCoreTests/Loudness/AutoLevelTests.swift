import CEchoDSP
@testable import EchoCore
import Foundation
import Synchronization
import Testing

struct OfflineEffectChainTests {
    private func run(_ chain: OfflineEffectChain, _ input: [[Float]], chunk: Int = 10_000) throws -> [[Float]] {
        var output = Array(repeating: [Float](), count: input.count)
        var offset = 0
        while offset < input[0].count {
            let end = min(offset + chunk, input[0].count)
            let part = chain.process(input.map { Array($0[offset..<end]) })
            for index in output.indices { output[index] += part[index] }
            offset = end
        }
        let tail = chain.finish()
        for index in output.indices { output[index] += tail[index] }
        return output
    }

    @Test func neutralSettingsLeaveTheAudioAndItsTimingAlone() throws {
        let input = [TestSignal.speechLike(frames: 30_000), TestSignal.speechLike(frames: 30_000).map { -$0 }]
        let chain = try OfflineEffectChain(manual: ManualSettings(), outputStage: nil, sampleRate: 48_000, channelCount: 2)
        #expect(try run(chain, input) == input, "bit-exact, the chain's delay removed")
    }

    @Test func settingsAndTheOutputStageApply() throws {
        var manual = ManualSettings()
        manual.inputGainDB = 6
        let input = [TestSignal.sine(440, amplitude: 0.01, frames: 30_000)]
        let chain = try OfflineEffectChain(
            manual: manual, outputStage: .init(autoLevelGainDB: 6), sampleRate: 48_000, channelCount: 1
        )
        let output = try run(chain, input)[0]

        #expect(output.count == input[0].count)
        let gain = echo.dsp.dbToLinear(12)
        #expect(zip(output, input[0]).map { abs($0 - $1 * gain) }.max()! < 1e-5)
    }

    @Test func theOutputStageHoldsTheCeiling() throws {
        let loud = [TestSignal.speechLike(frames: 30_000).map { $0 * 3 }]
        let chain = try OfflineEffectChain(manual: ManualSettings(), outputStage: .init(autoLevelGainDB: 0), sampleRate: 48_000, channelCount: 1)
        #expect(try run(chain, loud)[0].map(abs).max()! <= echo.dsp.dbToLinear(-1) * 1.001)
    }
}

final class AutoLevelAnalyzerTests {
    private let directory: URL

    init() throws {
        directory = try TestMedia.makeDirectory()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A stereo 1 kHz tone at `lufs` (a stereo tone's peak in dBFS equals its loudness, EBU 3341).
    private func tone(_ lufs: Double, seconds: Double = 10) throws -> URL {
        let amplitude = Float(pow(10, lufs / 20))
        let samples = (0..<Int(seconds * 48_000)).map { amplitude * Float(sin(2 * .pi * 1_000 * Double($0) / 48_000)) }
        let url = directory.appending(path: "tone-\(lufs).caf")
        try TestMedia.writeSamples([samples, samples], to: url)
        return url
    }

    private func gain(_ audio: URL, manual: ManualSettings = ManualSettings(), range: TimeRangeCodable = .full(duration: 10), target: LoudnessTarget) async throws -> Double {
        try await AutoLevelAnalyzer().gain(of: audio, manual: manual, range: range, target: target)
    }

    @Test func theGainReachesTheTarget() async throws {
        let audio = try tone(-30)
        #expect(abs(try await gain(audio, target: .youtube) - 16) < 0.1)
        #expect(abs(try await gain(audio, target: .podcast) - 14) < 0.1)
        #expect(abs(try await gain(audio, target: .custom(lufs: -23)) - 7) < 0.1)
    }

    @Test func theGainIsLimitedToTwentyDecibels() async throws {
        #expect(try await gain(try tone(-45), target: .youtube) == 20)
        #expect(try await gain(try tone(-3), target: .custom(lufs: -30)) == -20)
    }

    @Test func manualSettingsAreMeasuredToo() async throws {
        var manual = ManualSettings()
        manual.inputGainDB = 6
        #expect(abs(try await gain(try tone(-30), manual: manual, target: .youtube) - 10) < 0.1)
    }

    @Test func silenceNeedsNoGain() async throws {
        let silent = directory.appending(path: "silence.caf")
        try TestMedia.writeSamples([Array(repeating: 0, count: 96_000)], to: silent)
        #expect(try await gain(silent, target: .youtube) == 0)
    }

    @Test func theAnalysisReportsProgress() async throws {
        let values = Mutex<[Double]>([])
        _ = try await AutoLevelAnalyzer().gain(of: try tone(-30, seconds: 3), manual: ManualSettings(), range: .full(duration: 3), target: .youtube) { value in
            values.withLock { $0.append(value) }
        }
        let reported = values.withLock { $0 }
        #expect(reported.first == 0)
        #expect(reported.last == 1)
        #expect(reported.count > 2, "one value per second of audio")
    }

    @Test func onlyTheTrimRangeCounts() async throws {
        let quiet = Float(pow(10, -30.0 / 20)), loud = Float(pow(10, -10.0 / 20))
        let samples = (0..<480_000).map { frame in (frame < 240_000 ? quiet : loud) * Float(sin(2 * .pi * 1_000 * Double(frame) / 48_000)) }
        let audio = directory.appending(path: "mixed.caf")
        try TestMedia.writeSamples([samples, samples], to: audio)
        #expect(abs(try await gain(audio, range: TimeRangeCodable(start: 0, duration: 5), target: .youtube) - 16) < 0.15)
    }
}
