import AVFoundation
@testable import EchoCore
import Foundation
import Testing

struct VoiceLevelerCurveTests {
    /// Window RMS for a level in dBFS.
    private func rms(_ db: Float) -> Float { powf(10, db / 20) }

    @Test func speechMovesTowardsMinusTwentyWithinTwelveDecibels() {
        // Noise floor (−70) first, so the 10th percentile is the floor; phrases separated by pauses.
        let silence = Array(repeating: rms(-70), count: 20)
        let windows = silence + Array(repeating: rms(-26), count: 20) + silence + Array(repeating: rms(-40), count: 20)
            + silence + Array(repeating: rms(-10), count: 20)
        let gains = VoiceLevelerCurve.gains(windowRMS: windows, strength: 1)

        #expect(gains[0..<20].allSatisfy { $0 == 0 }, "silences are never boosted")
        #expect(gains[40..<60].allSatisfy { $0 == 0 })
        #expect(abs(gains[30] - 6) < 0.01, "−26 dBFS speech gets +6 dB")
        #expect(abs(gains[70] - 12) < 0.01, "−40 dBFS is clamped to +12 dB")
        #expect(abs(gains[110] + 10) < 0.01, "−10 dBFS gets −10 dB")
    }

    @Test func louderSpeechIsCutAheadAndQuieterSpeechRisesSlowly() {
        let windows = Array(repeating: rms(-70), count: 20) + Array(repeating: rms(-26), count: 20)
            + Array(repeating: rms(-14), count: 20) + Array(repeating: rms(-26), count: 40)
        let gains = VoiceLevelerCurve.gains(windowRMS: windows, strength: 1)

        // Loud speech starts at window 40: the gain starts falling 300 ms (6 windows) earlier and reaches −6 dB there.
        #expect(abs(gains[33] - 6) < 0.01)
        #expect(gains[34] < 6)
        #expect(gains[37] < gains[35])
        #expect(abs(gains[40] + 6) < 0.01)
        // Quiet again at 60: the gain rises with the 500 ms release, not at once.
        #expect(gains[61] < 0)
        #expect(gains[61] > -6)
        #expect(abs(gains[99] - 6) < 0.3)
    }

    @Test func aPhraseStartsAtItsLevelAfterAPause() {
        let windows = Array(repeating: rms(-70), count: 20) + Array(repeating: rms(-32), count: 20)
        let gains = VoiceLevelerCurve.gains(windowRMS: windows, strength: 1)
        #expect(gains[19] == 0)
        #expect(abs(gains[20] - 12) < 0.01, "no slow rise at the first word")
    }

    @Test func strengthScalesTheDepth() {
        let windows = Array(repeating: rms(-70), count: 20) + Array(repeating: rms(-30), count: 20)
        #expect(abs(VoiceLevelerCurve.gains(windowRMS: windows, strength: 0.5)[30] - 5) < 0.01)
        #expect(VoiceLevelerCurve.gains(windowRMS: windows, strength: 0).allSatisfy { $0 == 0 })
    }

    @Test func theSoftLimiterStaysUnderMinusOneDecibel() {
        #expect(VoiceLevelerCurve.softLimit(0.5) == 0.5)
        #expect(VoiceLevelerCurve.softLimit(4) <= 0.891)
        #expect(VoiceLevelerCurve.softLimit(-4) >= -0.891)
        #expect(VoiceLevelerCurve.softLimit(0.8) > 0.708)
    }
}

final class VoiceLevelerProcessorTests {
    private struct Layout: Decodable {
        struct Segment: Decodable {
            let speaker: String
            let start: Int
            let end: Int
        }
        let segments: [Segment]
    }

    private let directory: URL
    private let input: URL
    private let original: [Float]
    private let layout: Layout

    init() throws {
        directory = try TestMedia.makeDirectory()
        let clip = try #require(Bundle.module.url(forResource: "two-speakers", withExtension: "caf", subdirectory: "Resources/TestAudio"))
        let json = try #require(Bundle.module.url(forResource: "two-speakers", withExtension: "json", subdirectory: "Resources/TestAudio"))
        layout = try JSONDecoder().decode(Layout.self, from: Data(contentsOf: json))
        let file = try AVAudioFile(forReading: clip)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        original = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
        input = directory.appending(path: "working.caf")
        try TestMedia.writeSamples([original], to: input)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func level(strength: Float) async throws -> [Float] {
        let output = directory.appending(path: "level-\(strength).m4a")
        try await VoiceLevelerProcessor().process(AIOperation(kind: .voiceLeveler, strength: strength), input: input, output: output) { _ in }
        return try AIProcessorTests.read(output)[0]
    }

    private func speakerLevel(_ speaker: String, _ samples: [Float]) -> Float {
        TestSignal.rmsDB(layout.segments.filter { $0.speaker == speaker }.flatMap { samples[$0.start..<$0.end] })
    }

    private func pauseLevel(_ samples: [Float]) -> Float {
        var pauses: [Float] = []
        for (previous, next) in zip(layout.segments, layout.segments.dropFirst()) {
            // The middle of each pause, away from word tails and the interpolation at the edges.
            pauses += samples[(previous.end + 4_800)..<(next.start - 4_800)]
        }
        return TestSignal.rmsDB(pauses)
    }

    @Test func bothSpeakersEndUpNearMinusTwenty() async throws {
        let output = try await level(strength: 1)

        #expect(output.count == original.count)
        let gapBefore = speakerLevel("A", original) - speakerLevel("B", original)
        let gapAfter = speakerLevel("A", output) - speakerLevel("B", output)
        #expect(gapBefore > 17, "the sample's speakers are 18 dB apart")
        #expect(abs(gapAfter) < 4)
        #expect(abs(speakerLevel("A", output) + 20) < 3)
        #expect(abs(speakerLevel("B", output) + 20) < 3)
    }

    @Test func pausesAreNotBoostedAndPeaksStayUnderTheCeiling() async throws {
        let output = try await level(strength: 1)
        #expect(abs(pauseLevel(output) - pauseLevel(original)) < 1)
        #expect(output.map(abs).max()! <= max(original.map(abs).max()!, 0.891) + 1e-4, "boosts never go over −1 dBFS")
    }

    @Test func strengthScalesTheLeveling() async throws {
        let none = try await level(strength: 0)
        let half = try await level(strength: 0.5)

        #expect(zip(none, original).map { abs($0 - $1) }.max()! < 1e-4, "untouched: only 24-bit rounding")
        let boost = speakerLevel("B", half) - speakerLevel("B", original)
        #expect(boost > 4 && boost < 8, "about half of the quiet speaker's +12 dB")
    }

    @Test func matchesTheGoldenFile() async throws {
        let output = try await level(strength: 1)
        if let difference = try GoldenFile.differenceDB(of: output, name: "voice-leveler") {
            #expect(difference < GoldenFile.toleranceDB)
        }
    }
}
