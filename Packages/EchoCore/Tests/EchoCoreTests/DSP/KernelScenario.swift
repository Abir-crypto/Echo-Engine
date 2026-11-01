import CEchoDSP
import Testing

/// One kernel set up as in the chain, processing in 512-frame blocks with a parameter change halfway (at a block
/// boundary), so ramps are covered. Shared by the golden-file and allocation tests.
struct KernelScenario: Sendable, CustomTestStringConvertible {
    static let changeFrame = 6_144

    let name: String
    let run: @Sendable (ChannelBuffers) -> Void

    var testDescription: String { name }

    static let all: [KernelScenario] = [gain, equalizer, gate, compressor, deEsser, limiter]

    static let gain = KernelScenario(name: "gain") { buffers in
        var kernel = echo.dsp.GainKernel()
        kernel.prepare(TestSignal.sampleRate)
        kernel.setGainDB(4)
        buffers.processBlocks { channels, frames, start in
            if start == changeFrame { kernel.setGainDB(-8) }
            kernel.process(channels, Int32(buffers.channelCount), frames)
        }
    }

    static let equalizer = KernelScenario(name: "equalizer") { buffers in
        var kernel = echo.dsp.EQKernel()
        kernel.prepare(TestSignal.sampleRate)
        kernel.setBand(0, .lowShelf, 120, 4, 0.7)
        kernel.setBand(2, .peaking, 2_500, -6, 2)
        kernel.setBand(5, .highShelf, 8_000, 3, 0.7)
        buffers.processBlocks { channels, frames, start in
            if start == changeFrame { kernel.setBand(2, .peaking, 1_800, 6, 1.5) }
            kernel.process(channels, Int32(buffers.channelCount), frames)
        }
    }

    static let gate = KernelScenario(name: "gate") { buffers in
        var kernel = echo.dsp.GateKernel()
        kernel.prepare(TestSignal.sampleRate)
        kernel.setEnabled(true)
        kernel.setThresholdDB(-20)
        kernel.setRangeDB(-30)
        kernel.setAttackMs(1)
        kernel.setReleaseMs(80)
        buffers.processBlocks { channels, frames, start in
            if start == changeFrame { kernel.setThresholdDB(-35) }
            kernel.process(channels, Int32(buffers.channelCount), frames)
        }
    }

    static let compressor = KernelScenario(name: "compressor") { buffers in
        var kernel = echo.dsp.CompressorKernel()
        kernel.prepare(TestSignal.sampleRate)
        kernel.setEnabled(true)
        kernel.setThresholdDB(-18)
        kernel.setRatio(4)
        kernel.setAttackMs(5)
        kernel.setReleaseMs(80)
        kernel.setMakeupDB(3)
        buffers.processBlocks { channels, frames, start in
            if start == changeFrame { kernel.setRatio(8) }
            kernel.process(channels, Int32(buffers.channelCount), frames)
        }
    }

    static let deEsser = KernelScenario(name: "deesser") { buffers in
        var kernel = echo.dsp.DeEsserKernel()
        kernel.prepare(TestSignal.sampleRate)
        kernel.setEnabled(true)
        kernel.setFrequency(6_500)
        kernel.setAmount(1)
        buffers.processBlocks { channels, frames, start in
            if start == changeFrame { kernel.setFrequency(5_000) }
            kernel.process(channels, Int32(buffers.channelCount), frames)
        }
    }

    static let limiter = KernelScenario(name: "limiter") { buffers in
        var kernel = echo.dsp.LimiterKernel()
        kernel.prepare(TestSignal.sampleRate)
        kernel.setCeilingDB(-3)
        buffers.processBlocks { channels, frames, start in
            if start == changeFrame { kernel.setCeilingDB(-1) }
            kernel.process(channels, Int32(buffers.channelCount), frames)
        }
    }
}
