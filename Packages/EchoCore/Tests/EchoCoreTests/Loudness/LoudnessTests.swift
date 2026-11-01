import CEchoDSP
@testable import EchoCore
import Foundation
import Testing

/// EBU Tech 3341 / ITU-R BS.1770-4 reference cases (1 kHz tones; levels are each channel's peak in dBFS).
struct LoudnessMeterTests {
    private let sampleRate = 48_000.0

    private func tone(_ peakDB: Double, seconds: Double, frequency: Double = 1_000, phase: Double = 0) -> [Float] {
        let amplitude = pow(10, peakDB / 20)
        return (0..<Int(seconds * sampleRate)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / sampleRate + phase)) }
    }

    private func measure(_ channels: [[Float]], truePeak: Bool = false) -> (lufs: Double, dBTP: Double) {
        var meter = echo.dsp.LoudnessMeter()
        meter.prepare(sampleRate, Int32(channels.count), truePeak)
        let buffers = ChannelBuffers(channels)
        buffers.processBlocks(of: 48_000) { pointers, frames in
            let channels = UnsafeRawPointer(pointers).assumingMemoryBound(to: UnsafePointer<Float>?.self)
            meter.process(channels, Int32(buffers.channelCount), frames)
        }
        return (meter.integratedLUFS(), meter.truePeakDBTP())
    }

    private func stereo(_ samples: [Float]) -> [[Float]] { [samples, samples] }

    @Test func kWeightingMatchesTheStandardsTableAt48kHz() {
        let pre = echo.dsp.LoudnessMeter.preFilter(48_000)
        let rlb = echo.dsp.LoudnessMeter.highPass(48_000)
        // ITU-R BS.1770-4, tables 1 and 2.
        #expect(abs(pre.b0 - 1.53512485958697) < 1e-6)
        #expect(abs(pre.b1 + 2.69169618940638) < 1e-6)
        #expect(abs(pre.b2 - 1.19839281085285) < 1e-6)
        #expect(abs(pre.a1 + 1.69065929318241) < 1e-6)
        #expect(abs(pre.a2 - 0.73248077421585) < 1e-6)
        #expect(abs(rlb.a1 + 1.99004745483398) < 1e-6)
        #expect(abs(rlb.a2 - 0.99007225036621) < 1e-6)
    }

    @Test(arguments: [-23.0, -33.0])
    func aSteadyToneReadsItsLevel(_ level: Double) {
        // EBU 3341 cases 1 and 2.
        #expect(abs(measure(stereo(tone(level, seconds: 20))).lufs - level) < 0.1)
    }

    @Test func quietPartsAreGatedOut() {
        // EBU 3341 cases 3 and 4, at their full durations (shorter versions let blocks straddle the level changes).
        let case3 = tone(-36, seconds: 10) + tone(-23, seconds: 60) + tone(-36, seconds: 10)
        #expect(abs(measure(stereo(case3)).lufs + 23) < 0.1)
        let case4 = tone(-72, seconds: 10) + tone(-36, seconds: 10) + tone(-23, seconds: 60) + tone(-36, seconds: 10) + tone(-72, seconds: 10)
        #expect(abs(measure(stereo(case4)).lufs + 23) < 0.1)
    }

    @Test func mixedLevelsAverageInEnergy() {
        // EBU 3341 case 5.
        let signal = tone(-26, seconds: 20) + tone(-20, seconds: 20.1) + tone(-26, seconds: 20)
        #expect(abs(measure(stereo(signal)).lufs + 23) < 0.1)
    }

    @Test func monoCountsOneChannel() {
        #expect(abs(measure([tone(-23, seconds: 10)]).lufs + 26.01) < 0.1)
    }

    @Test func silenceHasNoLoudness() {
        let result = measure(stereo(Array(repeating: 0, count: 96_000)), truePeak: true)
        #expect(result.lufs.isNaN)
        #expect(result.dBTP == -.infinity)
    }

    @Test func truePeakFindsPeaksBetweenSamples() {
        // A 12 kHz sine shifted by 45°: every sample is at ±0.707 (−3 dB) but the waveform peaks at 0 dB.
        let shifted = tone(0, seconds: 1, frequency: 12_000, phase: .pi / 4)
        #expect(shifted.map(abs).max()! < 0.71)
        #expect(abs(measure([shifted], truePeak: true).dBTP) < 0.3)
        #expect(abs(measure([tone(-6.02, seconds: 1)], truePeak: true).dBTP + 6.02) < 0.1)
    }
}

final class EBUR128AnalyzerTests {
    private let directory: URL

    init() throws {
        directory = try TestMedia.makeDirectory()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func measuresOnlyTheRange() async throws {
        let amplitude: (Double) -> Float = { Float(pow(10, $0 / 20)) }
        let samples = (0..<288_000).map { frame -> Float in
            let level = frame < 144_000 ? amplitude(-15) : amplitude(-30)
            return level * Float(sin(2 * .pi * 1_000 * Double(frame) / 48_000))
        }
        let audio = directory.appending(path: "working.caf")
        try TestMedia.writeSamples([samples, samples], to: audio)

        let whole = try await EBUR128Analyzer().measure(audio, range: .full(duration: 6)) { _ in }
        let second = try await EBUR128Analyzer().measure(audio, range: TimeRangeCodable(start: 3, duration: 10)) { _ in }

        #expect(abs((second.integratedLUFS ?? 0) + 30) < 0.15)
        #expect(abs(second.truePeakDBTP + 30) < 0.1)
        #expect((whole.integratedLUFS ?? 0) > -20)
    }

    @Test func unreadableFilesAreReported() async throws {
        let garbage = directory.appending(path: "garbage.caf")
        try Data("not audio".utf8).write(to: garbage)
        await #expect(throws: LoudnessError.unreadable) {
            try await EBUR128Analyzer().measure(garbage, range: .full(duration: 1)) { _ in }
        }
    }
}
