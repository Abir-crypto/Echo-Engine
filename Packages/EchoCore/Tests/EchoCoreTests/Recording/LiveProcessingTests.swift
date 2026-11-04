import CEchoDSP
import EchoAudioUnits
import Foundation
import Testing

/// The live chain inside the capture core (SPEC § 13.4), through the render path.
struct LiveProcessingTests {
    private func core(rate: Double = 48_000) throws -> CaptureCore {
        let core = CaptureCore()
        try #require(core.configure(
            sampleRate: rate, inputChannelCount: 1, channels: [0], mixdownChannelCount: 1, maximumFrames: 512, ringFrames: 1 << 19
        ))
        return core
    }

    /// Captures `input` block by block (switching to `tier` at `switchAt`), returning raw, processed and monitor signals.
    private func run(
        _ core: CaptureCore, _ input: [Float], tier: Float = 0, switchAt: Int? = nil, to newTier: Float = 0
    ) -> (raw: [Float], processed: [Float], monitor: [Float]) {
        let harness = CaptureHarness(core: core, frames: 512)
        core.setParameterForTesting(.suppression, tier)
        core.setCapturing(true)
        var monitor: [Float] = []
        var start = 0
        while start < input.count {
            if let switchAt, start == switchAt { core.setParameterForTesting(.suppression, newTier) }
            let count = min(512, input.count - start)
            harness.fill(count) { _, frame in input[start + frame] }
            harness.process(count)
            monitor += harness.output(count)[0]
            start += count
        }
        let planes = harness.readAll()
        return (planes[0], planes[1], monitor)
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
    }

    /// A tone at the leveler's −20 dBFS target, so its gain stays near 0 dB.
    private func targetTone(_ frames: Int, rate: Float = 48_000) -> [Float] {
        (0..<frames).map { 0.1414 * sin(2 * .pi * 220 * Float($0) / rate) }
    }

    @Test func theProcessedTakeIsAConstantLatencyBehindTheRawOne() throws {
        let core = try core()
        #expect(core.processedLatencyFrames == processedLatency48k, "RNNoise's framing and delay, and the limiter's look-ahead")
        let input = targetTone(48_000)
        let off = run(core, input)
        let shifted = Array(off.processed[processedLatency48k...])
        #expect(alignment(off.raw, shifted, over: 4_800..<40_000) > 0.999, "Off: the input, a constant latency later")
        #expect(alignment(input, Array(off.monitor[72...]), over: 4_800..<40_000) > 0.999, "the monitor only waits for the limiter")
    }

    @Test func highFollowsTheSameTimeline() throws {
        let core = try core()
        let voice = try TestSignal.voice()
        let high = run(core, voice, tier: 2)
        // The lag where processed speech best matches the raw speech.
        let window = 48_000..<144_000
        let lags = 1_300...1_600
        let best = lags.max { lhs, rhs in
            correlation(high.raw, high.processed, lag: lhs, window: window) < correlation(high.raw, high.processed, lag: rhs, window: window)
        }
        #expect(best == core.processedLatencyFrames)
        #expect(Array(high.processed[100_000..<100_100]) == Array(high.monitor[100_000..<100_100]), "High's monitor is as late")
    }

    private func correlation(_ raw: [Float], _ processed: [Float], lag: Int, window: Range<Int>) -> Float {
        window.reduce(0) { $0 + raw[$1] * processed[$1 + lag] }
    }

    @Test func highRemovesSteadyNoise() throws {
        let core = try core()
        let noise = TestSignal.noise(amplitude: 0.05, frames: 96_000)
        let high = run(core, noise, tier: 2)
        let reduction = 20 * log10(rms(high.processed[48_000...]) / rms(high.raw[48_000...]))
        #expect(reduction < -15, "noise down by \(reduction) dB")
    }

    @Test func standardGatesQuietPartsOnly() throws {
        let core = try core()
        let quiet = TestSignal.noise(amplitude: 0.001, frames: 48_000)   // about −65 dBFS: below the gate
        let loud = targetTone(48_000)
        let standard = run(core, quiet + loud, tier: 1)
        #expect(rms(standard.monitor[24_000..<48_000]) < rms(quiet[24_000...]) * 0.2, "the gate closes on noise")
        #expect(abs(rms(standard.monitor[72_000..<96_000]) - rms(loud[24_000...])) < 0.01, "speech-level audio passes")
    }

    @Test func switchingToHighFadesWaitsAndComesBack() throws {
        let core = try core()
        let voice = try TestSignal.voice()
        let result = run(core, voice, tier: 0, switchAt: 48_128, to: 2)
        #expect(rms(result.monitor[24_000..<48_000]) > 0.01, "Off: speech before the switch")
        let silent = result.monitor[48_128 + 480..<48_128 + 1_440 + 480]
        #expect(silent.allSatisfy { $0 == 0 }, "silent while RNNoise fills")
        #expect(rms(result.monitor[96_000...]) > 0.01, "speech comes back through High")
        let jumps = zip(result.monitor[48_000..<48_700], result.monitor[48_001..<48_701]).map { abs($1 - $0) }
        #expect(jumps.max() ?? 0 < 0.1, "a fade, no click")
    }

    @Test func belowFullRateHighRunsAsStandard() throws {
        let core = try core(rate: 16_000)
        #expect(!core.supportsHigh)
        let loud = targetTone(16_000, rate: 16_000)
        let result = run(core, loud, tier: 2)
        // The gate (no RNNoise at 16 kHz) passes speech-level audio, a limiter look-ahead later.
        let latency = core.processedLatencyFrames - 1_440
        #expect(alignment(loud, Array(result.monitor[latency...]), over: 1_600..<14_000) > 0.999)
        #expect(abs(rms(result.monitor[4_000..<15_000]) - rms(loud[4_000..<15_000])) < 0.01)
    }

    // MARK: Gain, leveler, limiter (F11.T02)

    @Test func theLevelerMovesTowardMinus20ByAtMost6dB() throws {
        func settledLevel(_ amplitude: Float) throws -> Float {
            let core = try core()
            let tone = (0..<480_000).map { amplitude * sin(2 * .pi * 220 * Float($0) / 48_000) }
            let processed = run(core, tone).processed
            return 20 * log10(rms(processed[400_000..<470_000]))
        }
        let quietTone: Float = 0.0355   // −32 dBFS RMS
        let loudTone: Float = 0.56      // −8 dBFS RMS
        #expect(abs(try settledLevel(quietTone) - -26) < 1, "raised by the 6 dB maximum")
        #expect(abs(try settledLevel(loudTone) - -14) < 1, "lowered by the 6 dB maximum")
        #expect(abs(try settledLevel(0.1414) - -20) < 1, "left at the target")
    }

    @Test func theLevelerNeverRaisesQuietNoise() throws {
        let core = try core()
        let noise = TestSignal.noise(amplitude: 0.002, frames: 480_000)   // about −59 dBFS
        let off = run(core, noise).processed
        let change = 20 * log10(rms(off[400_000..<470_000]) / rms(noise[400_000..<470_000]))
        #expect(abs(change) < 0.5, "the gain held: \(change) dB")
    }

    @Test func theClipLimiterKeepsPeaksBelowMinus1dBFS() throws {
        let core = try core()
        core.setParameterForTesting(.inputGain, 12)
        let loud = (0..<96_000).map { 0.5 * sin(2 * .pi * 220 * Float($0) / 48_000) }   // 2.0 after the gain
        let processed = run(core, loud).processed
        let peak = processed[48_000...].map(abs).max() ?? 0
        #expect(peak <= 0.8913 + 0.005, "ceiling −1 dBFS, peak \(peak)")
        #expect(peak > 0.8, "limited, not silenced")
    }

    @Test func theMetersShowTheInputGain() throws {
        let core = try core()
        let harness = CaptureHarness(core: core, frames: 512)
        core.setParameterForTesting(.inputGain, 6)
        harness.fill(512) { _, _ in 0.25 }
        harness.process(512)
        let peak = try #require(core.takePeaks().first)
        #expect(abs(peak - 0.25 * 1.9953) < 1e-3, "+6 dB")
    }
}
