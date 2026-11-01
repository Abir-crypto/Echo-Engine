import AVFoundation
@testable import EchoCore
import Testing

struct RNNoiseDenoiserTests {
    private func denoise(_ input: [Float], chunks: [Int] = [4_800]) throws -> [Float] {
        let denoiser = try RNNoiseDenoiser()
        var output: [Float] = []
        var offset = 0
        var chunk = 0
        while offset < input.count {
            let count = min(chunks[chunk % chunks.count], input.count - offset)
            output += denoiser.process(Array(input[offset..<(offset + count)]))
            offset += count
            chunk += 1
        }
        return output + denoiser.finish()
    }

    @Test(arguments: [0, 1, 479, 480, 481, 5_000])
    func theOutputIsAsLongAsTheInput(_ frames: Int) throws {
        #expect(try denoise(TestSignal.irregularVoice(frames: max(frames, 1)).prefix(frames).map { $0 }).count == frames)
    }

    @Test func theOutputIsAlignedWithTheInputWhateverTheChunks() throws {
        let input = TestSignal.irregularVoice(frames: 96_000)
        let output = try denoise(input, chunks: [1_000, 333, 4_096, 7])

        #expect(TestSignal.bestLag(of: output, against: input, in: -1_000...1_000, over: 48_000..<60_000) == 0)
    }

    @Test func fanNoiseIsSuppressed() throws {
        let noise = TestSignal.fanNoise(frames: 144_000, rmsDB: -20)
        let output = try denoise(noise)
        #expect(TestSignal.rmsDB(output.suffix(48_000)) < TestSignal.rmsDB(noise.suffix(48_000)) - 15)
    }

    @Test func speechInFanNoiseComesOutCleaner() throws {
        let voice = try TestSignal.voice()
        let noisy = zip(voice, TestSignal.fanNoise(frames: voice.count, rmsDB: -35)).map(+)
        let output = try denoise(noisy)

        // RNNoise reshapes speech slightly (per-band gains), so judge the pauses and the speech separately.
        let frames = stride(from: 0, to: voice.count - 480, by: 480).map { $0..<($0 + 480) }
        let pauses = frames.filter { TestSignal.rmsDB(voice[$0]) < -60 }
        let speech = frames.filter { TestSignal.rmsDB(voice[$0]) > -40 }
        func level(_ signal: [Float], _ ranges: [Range<Int>]) -> Float {
            TestSignal.rmsDB(ranges.flatMap { signal[$0] })
        }
        try #require(pauses.count > 20 && speech.count > 100)

        #expect(level(output, pauses) < level(noisy, pauses) - 15, "the fan is gone between words")
        #expect(abs(level(output, speech) - level(voice, speech)) < 3, "the words keep their level")
    }

    @Test func buffersAreConvertedAndEachChannelIsDenoisedOnItsOwn() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        let noise = TestSignal.fanNoise(frames: 44_100, rmsDB: -20)
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<44_100 {
            channels[0][frame] = noise[frame]
            channels[1][frame] = 0
        }

        let denoised = try RNNoiseDenoiser.denoise(buffer)

        #expect(denoised.format.sampleRate == 48_000)
        #expect(denoised.format.channelCount == 2)
        #expect(abs(Int(denoised.frameLength) - 48_000) <= 2)
        let right = UnsafeBufferPointer(start: try #require(denoised.floatChannelData)[1], count: Int(denoised.frameLength))
        #expect(right.map(abs).max() ?? 1 < 1e-4, "silence stays silent: channels aren't mixed")
    }

    @Test func matchesTheGoldenFile() throws {
        let voice = try TestSignal.voice()
        let noisy = zip(voice, TestSignal.fanNoise(frames: voice.count, rmsDB: -35)).map(+)
        let output = try denoise(noisy)
        if let difference = try GoldenFile.differenceDB(of: output, name: "rnnoise-fan") {
            #expect(difference < GoldenFile.toleranceDB)
        }
    }
}
