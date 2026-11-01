import CEchoDSP
import Testing

/// Analytic checks of each kernel against values worked out by hand (SPEC § 8).
struct KernelTests {
    private let sampleRate = TestSignal.sampleRate

    // MARK: Gain

    @Test func gainRampsToTheExactLevel() {
        var kernel = echo.dsp.GainKernel()
        kernel.prepare(sampleRate)
        kernel.setGainDB(6)
        let buffers = ChannelBuffers([Array(repeating: 0.5, count: 4_800), Array(repeating: -0.25, count: 4_800)])

        buffers.processBlocks { kernel.process($0, 2, $1) }

        let expected = echo.dsp.dbToLinear(6)
        #expect(abs(buffers.output[0].last! - 0.5 * expected) < 1e-6)
        #expect(abs(buffers.output[1].last! + 0.25 * expected) < 1e-6)
        #expect(buffers.output[0][0] < 0.5 * expected, "ramps instead of jumping")
        #expect(buffers.output[0][0] >= 0.5)
    }

    @Test func gainIsClampedToTwentyFourDecibels() {
        var kernel = echo.dsp.GainKernel()
        kernel.setGainDB(40)
        kernel.prepare(sampleRate)
        let buffers = ChannelBuffers([[0.01]])
        buffers.processBlocks { kernel.process($0, 1, $1) }
        #expect(abs(buffers.output[0][0] - 0.01 * echo.dsp.dbToLinear(24)) < 1e-6)
    }

    // MARK: Equalizer

    @Test func peakingBandBoostsItsCenterAndLeavesFarFrequencies() {
        var kernel = echo.dsp.EQKernel()
        kernel.setBand(1, .peaking, 1_000, 12, 1)
        kernel.prepare(sampleRate)
        let center = ChannelBuffers([TestSignal.sine(1_000, amplitude: 0.05, frames: 9_600)])
        let far = ChannelBuffers([TestSignal.sine(80, amplitude: 0.05, frames: 9_600)])

        center.processBlocks { kernel.process($0, 1, $1) }
        kernel.reset()
        far.processBlocks { kernel.process($0, 1, $1) }

        let input = TestSignal.rmsDB(TestSignal.sine(1_000, amplitude: 0.05, frames: 4_800))
        #expect(abs(TestSignal.rmsDB(center.output[0].suffix(4_800)) - input - 12) < 0.2)
        #expect(abs(TestSignal.rmsDB(far.output[0].suffix(4_800)) - input) < 0.5)
        #expect(abs(kernel.magnitudeDB(1_000) - 12) < 0.01)
    }

    @Test func flatEqualizerPassesAudioUnchanged() {
        var kernel = echo.dsp.EQKernel()
        kernel.prepare(sampleRate)
        let input = TestSignal.speechLike()
        let buffers = ChannelBuffers([input])
        buffers.processBlocks { kernel.process($0, 1, $1) }
        #expect(buffers.output[0] == input)
    }

    // MARK: Gate

    @Test func gateClosesToItsRangeBelowTheThreshold() {
        var kernel = makeGate()
        let quiet = ChannelBuffers([TestSignal.sine(1_000, amplitude: 0.003_16, frames: 9_600)])   // −50 dBFS
        quiet.processBlocks { kernel.process($0, 1, $1) }

        let input = TestSignal.rmsDB(TestSignal.sine(1_000, amplitude: 0.003_16, frames: 2_400))
        #expect(abs(TestSignal.rmsDB(quiet.output[0].suffix(2_400)) - input + 40) < 0.5)
    }

    @Test func gateStaysOpenAboveTheThreshold() {
        var kernel = makeGate()
        let input = TestSignal.sine(1_000, amplitude: 0.316, frames: 9_600)   // −10 dBFS
        let loud = ChannelBuffers([input])
        loud.processBlocks { kernel.process($0, 1, $1) }
        // The silent first sample starts to close it; 1 ms attack reopens it long before the second half.
        let error = zip(loud.output[0].suffix(4_800), input.suffix(4_800)).map { abs($0 - $1) }.max() ?? 1
        #expect(error < 1e-5)
    }

    private func makeGate() -> echo.dsp.GateKernel {
        var kernel = echo.dsp.GateKernel()
        kernel.setEnabled(true)
        kernel.setThresholdDB(-30)
        kernel.setRangeDB(-40)
        kernel.setAttackMs(1)
        kernel.setReleaseMs(20)
        kernel.prepare(sampleRate)
        return kernel
    }

    // MARK: Compressor

    @Test func compressorReducesTheOvershootByItsRatio() {
        var kernel = echo.dsp.CompressorKernel()
        kernel.setEnabled(true)
        kernel.setThresholdDB(-18)
        kernel.setRatio(3)
        kernel.setAttackMs(1)
        kernel.setReleaseMs(50)
        kernel.prepare(sampleRate)
        let buffers = ChannelBuffers([Array(repeating: 0.5, count: 9_600)])   // −6.02 dBFS

        buffers.processBlocks { kernel.process($0, 1, $1) }

        // 11.98 dB over the threshold at 3:1 leaves 3.99 dB: 7.99 dB of reduction.
        let reduction = echo.dsp.linearToDb(buffers.output[0].last!) - echo.dsp.linearToDb(0.5)
        #expect(abs(reduction + 7.986) < 0.01)
    }

    @Test func compressorLeavesAudioBelowTheThreshold() {
        var kernel = echo.dsp.CompressorKernel()
        kernel.setEnabled(true)
        kernel.setThresholdDB(-18)
        kernel.prepare(sampleRate)
        let input = TestSignal.sine(440, amplitude: 0.05, frames: 4_800)   // −26 dBFS
        let buffers = ChannelBuffers([input])
        buffers.processBlocks { kernel.process($0, 1, $1) }
        #expect(buffers.output[0] == input)
    }

    // MARK: De-esser

    @Test func deEsserTurnsDownSibilanceOnly() {
        let sibilance = deEss(TestSignal.sine(7_000, amplitude: 0.316, frames: 9_600))
        let voice = deEss(TestSignal.sine(300, amplitude: 0.316, frames: 9_600))

        // 7 kHz is above the 6 kHz shelf midpoint: most of the 12 dB cut applies.
        let input = TestSignal.rmsDB(TestSignal.sine(7_000, amplitude: 0.316, frames: 4_800))
        #expect(TestSignal.rmsDB(sibilance.suffix(4_800)) < input - 6)
        let voiceInput = TestSignal.rmsDB(TestSignal.sine(300, amplitude: 0.316, frames: 4_800))
        #expect(abs(TestSignal.rmsDB(voice.suffix(4_800)) - voiceInput) < 0.05)
    }

    private func deEss(_ input: [Float]) -> [Float] {
        var kernel = echo.dsp.DeEsserKernel()
        kernel.setEnabled(true)
        kernel.setFrequency(6_000)
        kernel.setAmount(1)
        kernel.prepare(sampleRate)
        let buffers = ChannelBuffers([input])
        buffers.processBlocks { kernel.process($0, 1, $1) }
        return buffers.output[0]
    }

    // MARK: Off by default (SPEC § 8)

    @Test func gateCompressorAndDeEsserAreOffByDefault() {
        let input = TestSignal.speechLike()
        var gate = echo.dsp.GateKernel()
        var compressor = echo.dsp.CompressorKernel()
        var deEsser = echo.dsp.DeEsserKernel()
        var gain = echo.dsp.GainKernel()
        gate.prepare(sampleRate)
        compressor.prepare(sampleRate)
        deEsser.prepare(sampleRate)
        gain.prepare(sampleRate)
        let buffers = ChannelBuffers([input])

        buffers.processBlocks { channels, frames, _ in
            gain.process(channels, 1, frames)
            gate.process(channels, 1, frames)
            deEsser.process(channels, 1, frames)
            compressor.process(channels, 1, frames)
        }

        let error = zip(buffers.output[0], input).map { abs($0 - $1) }.max() ?? 0
        #expect(error < 1e-6, "a 0 dB shelf is flat")
    }

    // MARK: Limiter

    @Test func limiterNeverExceedsTheCeiling() {
        var kernel = echo.dsp.LimiterKernel()
        kernel.prepare(sampleRate)   // default ceiling −1 dB
        let hot = TestSignal.speechLike().map { $0 * 4 }
        let buffers = ChannelBuffers([hot, hot.map { -$0 * 0.5 }])

        buffers.processBlocks { kernel.process($0, 2, $1) }

        let ceiling = echo.dsp.dbToLinear(-1)
        #expect(buffers.output.joined().map(abs).max()! <= ceiling * (1 + 1e-5))
        #expect(hot.map(abs).max()! > 2, "the input really is hot")
    }

    @Test func limiterOnlyDelaysQuietAudio() {
        var kernel = echo.dsp.LimiterKernel()
        kernel.prepare(sampleRate)
        let latency = Int(kernel.latencyFrames())
        let input = TestSignal.sine(440, amplitude: 0.5, frames: 4_800)
        let buffers = ChannelBuffers([input])

        buffers.processBlocks { kernel.process($0, 1, $1) }

        #expect(latency == 72, "1.5 ms at 48 kHz")
        #expect(buffers.output[0].prefix(latency).allSatisfy { $0 == 0 })
        let error = zip(buffers.output[0].dropFirst(latency), input).map { abs($0 - $1) }.max() ?? 1
        #expect(error < 1e-5)
    }
}
