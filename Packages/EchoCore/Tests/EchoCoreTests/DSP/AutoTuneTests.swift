import CEchoDSP
import CEchoDSPTestSupport
import Foundation
import Testing

/// Live auto-tune (SPEC § 13.5) on synthetic singing.
struct AutoTuneTests {
    private static let rate = TestSignal.sampleRate

    /// A vowel sung at `midi` notes (each `detune` cents off, with `vibrato` cents of 5 Hz vibrato), `seconds` each.
    static func sung(_ notes: [Double], detune: [Double], vibrato: Double = 0, seconds: Double = 0.5) -> [Float] {
        var resonators = [700.0, 1_200].map { (echo.dsp.makeBiquad(.bandPass, rate, $0, 0, 5), echo.dsp.BiquadState()) }
        let framesPerNote = Int(seconds * rate)
        var phase = 0.0
        var raw: [Float] = []
        for (index, note) in notes.enumerated() {
            for frame in 0..<framesPerNote {
                let time = Double(frame) / rate
                let cents = detune[index] + vibrato * sin(2 * .pi * 5 * time)
                phase += 440 * pow(2, (note + cents / 100 - 69) / 12) / rate
                var pulse: Float = 0
                if phase >= 1 {
                    phase -= 1
                    pulse = 1
                }
                var output: Float = 0
                for resonator in resonators.indices {
                    output += resonators[resonator].1.process(resonators[resonator].0, pulse, 0)
                }
                raw.append(output)
            }
        }
        let peak = raw.map(abs).max() ?? 1
        return raw.map { $0 * 0.5 / peak }
    }

    private func tune(_ input: [Float], key: Int32 = -1, minor: Bool = false, retuneMs: Float = 0, humanize: Float = 0,
                      formants: Bool = true) -> (output: [Float], latency: Int) {
        var kernel = echo.dsp.AutoTuneKernel()
        kernel.prepare(Self.rate)
        kernel.setKey(key)
        kernel.setMinor(minor)
        kernel.setRetuneMs(retuneMs)
        kernel.setHumanize(humanize)
        kernel.setPreservesFormants(formants)
        let buffers = ChannelBuffers([input])
        buffers.processBlocks { kernel.process($0, 1, $1) }
        return (buffers.output[0], Int(kernel.latencyFrames()))
    }

    /// The pitch (MIDI) of `samples` over 100 ms ending at `end`.
    private func midi(_ samples: [Float], endingAt end: Int) throws -> Double {
        let frequency = try #require(TestSignal.detectedFrequency(Array(samples[(end - 4_800)..<end])))
        return 69 + 12 * log2(frequency / 440)
    }

    // C major scale, sung off by 20–35 cents each way.
    private let scale: [Double] = [60, 62, 64, 65, 67, 69, 71, 72]
    private let detune: [Double] = [30, -25, 35, -30, 20, -35, 25, -20]

    @Test func snapsASungScaleToCMajor() throws {
        let input = Self.sung(scale, detune: detune)
        let (output, latency) = tune(input, key: 0)
        for (index, note) in scale.enumerated() {
            let end = (index + 1) * 24_000 - 2_400 + latency
            let sung = try midi(input, endingAt: end - latency)
            let tuned = try midi(output, endingAt: end)
            #expect(abs(sung - note) > 0.15, "sung off-pitch")
            #expect(abs(tuned - note) < 0.1, "note \(note): sung \(sung), tuned \(tuned)")
        }
        let difference = try #require(try GoldenFile.differenceDB(of: output, name: "auto-tune-c-major") ?? GoldenFile.toleranceDB - 1)
        #expect(difference < GoldenFile.toleranceDB)
    }

    @Test func aKeyAndScaleChooseTheNearestAllowedNote() {
        typealias Kernel = echo.dsp.AutoTuneKernel
        #expect(Kernel.nearestNote(61.4, -1, false) == 61, "chromatic: the nearest semitone")
        #expect(Kernel.nearestNote(61.4, 0, false) == 62, "C# isn't in C major")
        #expect(Kernel.nearestNote(66.2, 0, false) == 67)
        #expect(Kernel.nearestNote(68, 9, true) == 67, "A minor: G#, halfway, goes down to G")
        #expect(Kernel.nearestNote(70.6, 9, true) == 71, "B is in A minor")
    }

    @Test func naturalGlidesWhereRoboticJumps() throws {
        let input = Self.sung([62], detune: [40], seconds: 1)
        /// The correction after `frames` of the note.
        func correction(retuneMs: Float, after frames: Int) -> Float {
            var kernel = echo.dsp.AutoTuneKernel()
            kernel.prepare(Self.rate)
            kernel.setRetuneMs(retuneMs)
            let buffers = ChannelBuffers([Array(input[..<frames])])
            buffers.processBlocks { kernel.process($0, 1, $1) }
            return kernel.correction()
        }
        let robotic = correction(retuneMs: 0, after: 2_880 + 2_400)
        let natural = correction(retuneMs: 100, after: 2_880 + 2_400)
        #expect(abs(robotic + 0.4) < 0.03, "robotic: the whole 40 cents at once (\(robotic))")
        #expect(abs(natural) < abs(robotic) * 0.7, "natural: still on its way (\(natural))")
        #expect(abs(correction(retuneMs: 100, after: 40_000) + 0.4) < 0.03, "natural: there in the end")
        let tuned = tune(input, retuneMs: 100)
        #expect(abs(try midi(tuned.output, endingAt: 40_000 + tuned.latency) - 62) < 0.1)
    }

    @Test func humanizeKeepsAHeldNotesVibrato() throws {
        let input = Self.sung([64], detune: [0], vibrato: 25, seconds: 2)
        func spread(_ output: [Float], latency: Int) throws -> Double {
            let readings = try stride(from: 30_000, to: 90_000, by: 2_400).map { try midi(output, endingAt: $0 + latency) }
            return (readings.max() ?? 0) - (readings.min() ?? 0)
        }
        let strict = tune(input, retuneMs: 0, humanize: 0)
        let loose = tune(input, retuneMs: 0, humanize: 1)
        let looseSpread = try spread(loose.output, latency: loose.latency)
        let strictSpread = try spread(strict.output, latency: strict.latency)
        #expect(looseSpread > strictSpread + 0.15, "humanized \(looseSpread), strict \(strictSpread) semitones")
    }

    @Test func notesBelowG2PassUncorrected() throws {
        let input = Self.sung([42], detune: [30], seconds: 1)   // F#2, 92.5 Hz
        let (output, latency) = tune(input, key: 0)
        #expect(abs(try midi(output, endingAt: 40_000 + latency) - (42.3)) < 0.1)
    }

    @Test func itsDelayFollowsG2() {
        var kernel = echo.dsp.AutoTuneKernel()
        kernel.prepare(Self.rate)
        #expect(kernel.latencyFrames() == 490 * 5 / 2, "2.5 periods of 98 Hz: about 25.5 ms")
    }

    @Test func withoutFormantPreservationTheVoiceColourMoves() throws {
        let vowel = TestSignal.vowel(f0: 150, frames: 48_000)
        func centroid(preserving: Bool) -> Double {
            var kernel = echo.dsp.PitchShiftKernel()
            kernel.prepare(Self.rate, 98)
            kernel.setPreservesFormants(preserving)
            kernel.setControlledShift(7, 1)
            let buffers = ChannelBuffers([vowel])
            buffers.processBlocks { kernel.process($0, 1, $1) }
            return TestSignal.spectralCentroid(Array(buffers.output[0][24_000...]))
        }
        let original = TestSignal.spectralCentroid(Array(vowel[24_000...]))
        #expect(abs(centroid(preserving: true) / original - 1) < 0.1, "formants kept")
        #expect(centroid(preserving: false) / original > 1.2, "formants moved up with the pitch")
    }

    @Test func processingNeverAllocates() {
        var kernel = echo.dsp.AutoTuneKernel()
        kernel.prepare(Self.rate)
        kernel.setKey(0)
        let buffers = ChannelBuffers([Self.sung([60, 62], detune: [30, -30], seconds: 0.25)])
        echo.test.beginAllocationGuard()
        buffers.processBlocks { kernel.process($0, 1, $1) }
        #expect(echo.test.endAllocationGuard() == 0)
    }
}
