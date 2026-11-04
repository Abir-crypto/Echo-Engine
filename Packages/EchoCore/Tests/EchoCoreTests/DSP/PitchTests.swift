import CEchoDSP
import Testing

/// SPEC § 19: pitch detection on synthetic tones.
struct PitchDetectorTests {
    @Test(arguments: [100.0, 220, 440, 800])
    func findsTheFrequencyOfASine(_ frequency: Double) throws {
        let detected = try #require(TestSignal.detectedFrequency(TestSignal.sine(frequency, amplitude: 0.5, frames: 4_800)))
        #expect(abs(detected / frequency - 1) < 0.01)
    }

    @Test func findsTheFundamentalOfAVoice() throws {
        let detected = try #require(TestSignal.detectedFrequency(TestSignal.vowel(f0: 150, frames: 4_800)))
        #expect(abs(detected / 150 - 1) < 0.01)
    }

    /// Auto-tune snaps to the nearest note, so the estimate must sit well inside a semitone (100 cents): E2 to A5.
    @Test(arguments: [82.41, 110, 146.83, 196, 261.63, 329.63, 440, 587.33, 880])
    func findsNotesWithinFiveCents(_ frequency: Double) throws {
        let detected = try #require(TestSignal.detectedFrequency(TestSignal.sine(frequency, amplitude: 0.3, frames: 9_600)))
        #expect(abs(1_200 * log2(detected / frequency)) < 5, "\(detected) Hz for \(frequency) Hz")
    }

    /// Strong harmonics (a sawtooth) must not be taken for the octave above.
    @Test(arguments: [98.0, 220, 523.25])
    func harmonicsDontFoolIt(_ frequency: Double) throws {
        let sawtooth = (0..<9_600).map { frame in
            Float(0.3 * (2 * (Double(frame) * frequency / TestSignal.sampleRate).truncatingRemainder(dividingBy: 1) - 1))
        }
        let detected = try #require(TestSignal.detectedFrequency(sawtooth))
        #expect(abs(1_200 * log2(detected / frequency)) < 5, "\(detected) Hz for \(frequency) Hz")
    }

    /// A slow glide (one semitone a second) is followed window by window.
    @Test func followsAGlide() throws {
        var detector = echo.dsp.PitchDetector()
        detector.prepare(TestSignal.sampleRate)
        var phase = 0.0
        var worst = 0.0
        for frame in 0..<96_000 {
            let frequency = 220 * pow(2, Double(frame) / TestSignal.sampleRate / 12)
            phase += 2 * .pi * frequency / TestSignal.sampleRate
            detector.push(Float(0.3 * sin(phase)))
            if frame > 9_600, frame % 4_800 == 0 {
                let estimate = detector.detect()
                try #require(estimate.period > 0)
                // The window is centred about half a window back.
                let expected = 220 * pow(2, (Double(frame) - Double(detector.windowFrames()) / 2) / TestSignal.sampleRate / 12)
                worst = max(worst, abs(1_200 * log2(TestSignal.sampleRate / Double(estimate.period) / expected)))
            }
        }
        #expect(worst < 8, "worst \(worst) cents")
    }

    @Test func noiseAndSilenceAreUnvoiced() {
        #expect(TestSignal.detectedFrequency(TestSignal.noise(amplitude: 0.5, frames: 4_800)) == nil)
        #expect(TestSignal.detectedFrequency(Array(repeating: 0, count: 4_800)) == nil)
    }
}

struct PitchShiftTests {
    private func shift(_ input: [Float], semitones: Float) -> (output: [Float], latency: Int) {
        var kernel = echo.dsp.PitchShiftKernel()
        kernel.prepare(TestSignal.sampleRate)
        kernel.setSemitones(semitones)
        let buffers = ChannelBuffers([input])
        buffers.processBlocks { kernel.process($0, 1, $1) }
        return (buffers.output[0], Int(kernel.latencyFrames()))
    }

    @Test func zeroSemitonesIsTheInputDelayed() {
        let input = TestSignal.speechLike()
        let (output, latency) = shift(input, semitones: 0)

        #expect(latency == 1_715, "2.5 periods of 70 Hz at 48 kHz")
        #expect(output.prefix(latency).allSatisfy { $0 == 0 })
        #expect(Array(output.dropFirst(latency)) == Array(input.prefix(input.count - latency)))
    }

    @Test(arguments: [12, 5, -5, -12] as [Float])
    func movesThePitchBySemitones(_ semitones: Float) throws {
        let (output, _) = shift(TestSignal.vowel(f0: 150, frames: 28_800), semitones: semitones)

        let detected = try #require(TestSignal.detectedFrequency(Array(output.suffix(9_600))))
        let expected = 150 * pow(2, Double(semitones) / 12)
        #expect(abs(detected / expected - 1) < 0.03)
    }

    @Test(arguments: [12, 5, -5, -12] as [Float])
    func keepsTheLoudness(_ semitones: Float) {
        let input = TestSignal.vowel(f0: 150, frames: 28_800)
        let (output, _) = shift(input, semitones: semitones)
        #expect(abs(TestSignal.rmsDB(output.suffix(9_600)) - TestSignal.rmsDB(input.suffix(9_600))) < 1.5)
    }

    @Test func keepsTheFormants() {
        let input = TestSignal.vowel(f0: 150, frames: 28_800)
        let (output, _) = shift(input, semitones: 5)

        // The pitch rises by a third; a plain resample would move the spectral envelope with it.
        let ratio = TestSignal.spectralCentroid(Array(output.suffix(9_600))) / TestSignal.spectralCentroid(Array(input.suffix(9_600)))
        #expect(abs(ratio - 1) < 0.1)
    }

    @Test func returningToZeroGoesBackToTheDelayedInput() {
        var kernel = echo.dsp.PitchShiftKernel()
        kernel.prepare(TestSignal.sampleRate)
        let input = TestSignal.vowel(f0: 150, frames: 24_000)
        let buffers = ChannelBuffers([input])
        kernel.setSemitones(7)
        buffers.processBlocks { channels, frames, start in
            if start == 9_728 { kernel.setSemitones(0) }
            kernel.process(channels, 1, frames)
        }

        let latency = Int(kernel.latencyFrames())
        let tail = Array(buffers.output[0].suffix(4_800))
        let delayed = Array(input[(input.count - 4_800 - latency)..<(input.count - latency)])
        #expect(tail == delayed)
    }
}

struct ReverbTests {
    private func reverb(
        _ input: [Float], roomSize: Float = 0.5, damping: Float = 0.5, mix: Float = 1, enabled: Bool = true
    ) -> [Float] {
        var kernel = echo.dsp.ReverbKernel()
        kernel.setEnabled(enabled)
        kernel.setRoomSize(roomSize)
        kernel.setDamping(damping)
        kernel.setMix(mix)
        kernel.prepare(TestSignal.sampleRate)
        let buffers = ChannelBuffers([input])
        buffers.processBlocks { kernel.process($0, 1, $1) }
        return buffers.output[0]
    }

    private var impulse: [Float] {
        [1] + Array(repeating: 0, count: 47_999)
    }

    @Test func offByDefaultAndAtZeroMix() {
        let input = TestSignal.speechLike()
        var kernel = echo.dsp.ReverbKernel()
        kernel.prepare(TestSignal.sampleRate)
        let buffers = ChannelBuffers([input])
        buffers.processBlocks { kernel.process($0, 1, $1) }

        #expect(buffers.output[0] == input)
        #expect(reverb(input, mix: 0) == input)
    }

    @Test func aLargerRoomRingsLonger() {
        let small = reverb(impulse, roomSize: 0.2)
        let large = reverb(impulse, roomSize: 0.9)

        #expect(TestSignal.rms(small[4_800..<14_400]) > 0, "it has a tail")
        #expect(TestSignal.rmsDB(large[24_000...]) > TestSignal.rmsDB(small[24_000...]) + 10)
    }

    @Test func dampingDarkensTheTail() {
        func brightness(_ samples: ArraySlice<Float>) -> Float {
            let differences = zip(samples.dropFirst(), samples).map { $0 - $1 }
            return TestSignal.rms(differences) / TestSignal.rms(samples)
        }
        let bright = reverb(impulse, damping: 0)
        let dark = reverb(impulse, damping: 1)
        #expect(brightness(dark[9_600..<24_000]) < brightness(bright[9_600..<24_000]) * 0.8)
    }

    @Test func turningItBackOnStartsWithoutTheOldTail() {
        var kernel = echo.dsp.ReverbKernel()
        kernel.setEnabled(true)
        kernel.setMix(1)
        kernel.prepare(TestSignal.sampleRate)
        let loud = ChannelBuffers([impulse])
        loud.processBlocks { kernel.process($0, 1, $1) }

        kernel.setEnabled(false)
        let fadeOut = ChannelBuffers([Array(repeating: 0, count: 4_800)])
        fadeOut.processBlocks { kernel.process($0, 1, $1) }
        kernel.setEnabled(true)
        let silence = ChannelBuffers([Array(repeating: 0, count: 4_800)])
        silence.processBlocks { kernel.process($0, 1, $1) }

        #expect(silence.output[0].allSatisfy { $0 == 0 })
    }
}
