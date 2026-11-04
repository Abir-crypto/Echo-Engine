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

    @Test func theProcessedTakeIsAConstantLatencyBehindTheRawOne() throws {
        let core = try core()
        let latency = core.processedLatencyFrames
        #expect(latency == 1_440, "RNNoise's framing and its own delay")
        let input = (0..<9_600).map { Float($0 % 977) / 977 - 0.5 }
        let off = run(core, input)
        #expect(Array(off.processed[latency...]) == Array(off.raw[..<(off.raw.count - latency)]), "Off: the input, later")
        #expect(off.monitor == input, "the monitor isn't delayed without High")
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
        let loud = (0..<48_000).map { 0.5 * sin(Float($0) * 0.05) }
        let standard = run(core, quiet + loud, tier: 1)
        #expect(rms(standard.monitor[24_000..<48_000]) < rms(quiet[24_000...]) * 0.2, "the gate closes on noise")
        #expect(abs(rms(standard.monitor[72_000..<96_000]) - rms(loud[24_000...])) < 0.01, "speech-level audio passes")
    }

    @Test func switchingToHighFadesWaitsAndComesBack() throws {
        let core = try core()
        let voice = try TestSignal.voice()
        let result = run(core, voice, tier: 0, switchAt: 48_128, to: 2)
        #expect(Array(result.monitor[..<48_128]) == Array(voice[..<48_128]), "Off until the switch")
        let silent = result.monitor[48_128 + 480..<48_128 + 1_440 + 480]
        #expect(silent.allSatisfy { $0 == 0 }, "silent while RNNoise fills")
        #expect(rms(result.monitor[96_000...]) > 0.01, "speech comes back through High")
        let jumps = zip(result.monitor[48_000..<48_700], result.monitor[48_001..<48_701]).map { abs($1 - $0) }
        #expect(jumps.max() ?? 0 < 0.1, "a fade, no click")
    }

    @Test func belowFullRateHighRunsAsStandard() throws {
        let core = try core(rate: 16_000)
        #expect(!core.supportsHigh)
        let loud = (0..<16_000).map { 0.5 * sin(Float($0) * 0.1) }
        let result = run(core, loud, tier: 2)
        // Once the gate has opened (2 ms attack), loud audio passes unchanged: no RNNoise at 16 kHz.
        let difference = zip(result.monitor[1_600...], loud[1_600...]).map { abs($0 - $1) }.max() ?? 1
        #expect(difference < 1e-3)
    }
}
