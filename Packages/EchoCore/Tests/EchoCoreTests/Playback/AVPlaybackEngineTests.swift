import AVFoundation
import CEchoDSP
@testable import EchoCore
import Foundation
import Testing

/// Offline-rendered: the source's sample at frame `n` is `n / 1_000_000`, so every output sample says which source
/// frame was played.
@MainActor
final class AVPlaybackEngineTests {
    private let directory: URL
    private let audio: URL
    private let sampleRate: Double = 48_000
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    init() throws {
        directory = try TestMedia.makeDirectory()
        audio = directory.appending(path: "working.caf")
        try TestMedia.writeSamples([(0..<96_000).map { Float($0) / 1_000_000 }], to: audio)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeEngine() throws -> AVPlaybackEngine {
        let engine = try AVPlaybackEngine(manualRenderingFormat: format)
        try engine.load(audio: audio, video: nil)
        return engine
    }

    /// Source frame of each rendered sample, rendering at most 4,096 frames per call (the engine's maximum).
    private func render(_ engine: AVPlaybackEngine, frames: Int) throws -> [Int] {
        var played: [Int] = []
        while played.count < frames {
            let buffer = try engine.renderOffline(frames: AVAudioFrameCount(min(4_096, frames - played.count)))
            let samples = try #require(buffer.floatChannelData?[0])
            played += (0..<Int(buffer.frameLength)).map { Int((samples[$0] * 1_000_000).rounded()) }
        }
        return played
    }

    /// Renders until `frames` frames have left the chain (after its latency): right after `play` or a seek, when the
    /// chain is empty.
    private func renderHeard(_ engine: AVPlaybackEngine, frames: Int) throws -> [Int] {
        let latency = engine.chainLatencyFrames
        return Array(try render(engine, frames: latency + frames).dropFirst(latency))
    }

    /// Raw output samples, rendering at most 4,096 frames per call.
    private func renderSamples(_ engine: AVPlaybackEngine, frames: Int) throws -> [Float] {
        var samples: [Float] = []
        while samples.count < frames {
            let buffer = try engine.renderOffline(frames: AVAudioFrameCount(min(4_096, frames - samples.count)))
            let channel = try #require(buffer.floatChannelData?[0])
            samples += UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        }
        return samples
    }

    /// Waits (up to 2 s) for the engine's end-of-range callback to reach the main actor.
    private func waitUntilStopped(_ engine: AVPlaybackEngine) async throws {
        for _ in 0..<200 where engine.isPlaying {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func loadingSetsDurationAndFullRange() throws {
        let engine = try makeEngine()
        #expect(engine.duration == 2)
        #expect(engine.playbackRange == TimeRangeCodable(start: 0, duration: 2))
        #expect(!engine.isPlaying)
        #expect(engine.currentTime == 0)
    }

    @Test func playsFromTheTrimStart() throws {
        let engine = try makeEngine()
        engine.playbackRange = TimeRangeCodable(start: 0.5, duration: 1)

        try engine.play()
        let frames = try renderHeard(engine, frames: 1_024)

        #expect(frames == Array(24_000..<25_024))
        #expect(abs(engine.currentTime - (0.5 + 1_024 / sampleRate)) < 0.001)
    }

    @Test func stopsAtTheTrimEndAndRestartsFromTheStart() async throws {
        let engine = try makeEngine()
        engine.playbackRange = TimeRangeCodable(start: 1, duration: 0.05)

        try engine.play()
        let played = try renderHeard(engine, frames: 8_192)
        try await waitUntilStopped(engine)

        #expect(Array(played.prefix(2_400)) == Array(48_000..<50_400), "the range's end leaves the chain too")
        #expect(played.dropFirst(2_400).allSatisfy { $0 == 0 }, "silence after the range end")
        #expect(!engine.isPlaying)
        #expect(engine.currentTime == 1.05)

        try engine.play()
        #expect(try renderHeard(engine, frames: 4).first == 48_000)
    }

    @Test func seekWhilePlayingContinuesFromTheNewTime() throws {
        let engine = try makeEngine()
        try engine.play()
        _ = try render(engine, frames: 512)

        engine.seek(to: 1.5)
        let frames = try renderHeard(engine, frames: 256)

        #expect(frames == Array(72_000..<72_256), "audio from before the seek is cleared from the chain")
        #expect(engine.isPlaying)
    }

    @Test func seekIsClampedToTheRange() throws {
        let engine = try makeEngine()
        engine.playbackRange = TimeRangeCodable(start: 0.5, duration: 1)

        engine.seek(to: 0.1)
        #expect(engine.currentTime == 0.5)
        engine.seek(to: 1.9)
        #expect(engine.currentTime == 1.5)
    }

    @Test func pauseKeepsThePlayheadAndPlayResumesThere() throws {
        let engine = try makeEngine()
        try engine.play()
        _ = try renderHeard(engine, frames: 4_800)

        engine.pause()
        #expect(!engine.isPlaying)
        #expect(abs(engine.currentTime - 0.1) < 0.001, "the playhead is what has been heard")

        try engine.play()
        #expect(try renderHeard(engine, frames: 2).first == 4_800)
    }

    @Test func trimmingAroundThePlayheadMovesItInside() throws {
        let engine = try makeEngine()
        engine.seek(to: 0.2)

        engine.playbackRange = TimeRangeCodable(start: 1, duration: 0.5)

        #expect(engine.currentTime == 1)
    }

    @Test func seekingToTheRangeEndWhilePlayingStops() throws {
        let engine = try makeEngine()
        try engine.play()
        _ = try render(engine, frames: 512)

        engine.seek(to: 5)

        #expect(!engine.isPlaying)
        #expect(engine.currentTime == 2)
    }

    @Test func shorteningTheEndWhilePlayingStopsAtTheNewEnd() async throws {
        let engine = try makeEngine()
        try engine.play()
        _ = try renderHeard(engine, frames: 4_800)

        engine.playbackRange = TimeRangeCodable(start: 0, duration: 0.15)
        let played = try renderHeard(engine, frames: 8_192)
        try await waitUntilStopped(engine)

        #expect(Array(played.prefix(2_400)) == Array(4_800..<7_200))
        #expect(played.dropFirst(2_400).allSatisfy { $0 == 0 }, "silence after the new end")
        #expect(!engine.isPlaying)
        #expect(engine.currentTime == 0.15)
    }

    @Test func extendingTheEndWhilePlayingPlaysOn() async throws {
        let engine = try makeEngine()
        engine.playbackRange = TimeRangeCodable(start: 0, duration: 0.1)
        try engine.play()
        _ = try renderHeard(engine, frames: 2_400)

        engine.playbackRange = TimeRangeCodable(start: 0, duration: 0.2)
        let played = try renderHeard(engine, frames: 4_800)

        #expect(played == Array(2_400..<7_200))
        #expect(engine.isPlaying)
    }

    @Test func movingTheEndBeforeThePlayheadWhilePlayingStopsThere() throws {
        let engine = try makeEngine()
        try engine.play()
        _ = try renderHeard(engine, frames: 9_600)

        engine.playbackRange = TimeRangeCodable(start: 0, duration: 0.1)

        #expect(!engine.isPlaying)
        #expect(engine.currentTime == 0.1)
    }

    @Test func theChainDelaysByThePitchAndLimiterLookAhead() throws {
        let engine = try makeEngine()
        try engine.play()

        #expect(engine.chainLatencyFrames == 1_715 + 72)
        #expect(try renderSamples(engine, frames: 1_787).allSatisfy { $0 == 0 })
        #expect(try render(engine, frames: 1).first == 0, "then the first frame")
    }

    @Test func manualSettingsShapeTheSound() throws {
        let engine = try makeEngine()
        var manual = ManualSettings()
        manual.inputGainDB = 6
        engine.apply(manual)

        try engine.play()
        _ = try renderSamples(engine, frames: engine.chainLatencyFrames)
        let samples = try renderSamples(engine, frames: 1_024)

        let gain = echo.dsp.dbToLinear(6)
        #expect(zip(samples, 0..<1_024).allSatisfy { abs($0 - Float($1) / 1_000_000 * gain) < 1e-6 })
    }

    @Test func changesWhilePlayingReachTheChainAndRamp() throws {
        let engine = try makeEngine()
        try engine.play()
        _ = try renderHeard(engine, frames: 1_024)

        var manual = ManualSettings()
        manual.inputGainDB = -6
        engine.apply(manual)
        let samples = try renderSamples(engine, frames: 4_800)

        let gain = echo.dsp.dbToLinear(-6)
        let input = Float(1_024 + 4_799) / 1_000_000
        #expect(abs(samples[samples.count - 1] - input * gain) < 1e-6, "settled after the 30 ms ramp")
        #expect(abs(samples[0] - Float(1_024) / 1_000_000) < 1e-6, "no jump: the first frame is still at unity")
    }

    @Test func holdingForTheOriginalBypassesTheChainWithoutShiftingTime() throws {
        let engine = try makeEngine()
        var manual = ManualSettings()
        manual.inputGainDB = 6
        engine.apply(manual)
        try engine.play()
        _ = try renderHeard(engine, frames: 1_024)

        engine.holdOriginal(true)
        let held = try render(engine, frames: 4_800)
        #expect(Array(held.suffix(2_400)) == Array((1_024 + 2_400)..<(1_024 + 4_800)), "the original, at the same time")

        engine.holdOriginal(false)
        let released = try renderSamples(engine, frames: 4_800)
        let gain = echo.dsp.dbToLinear(6)
        #expect(abs(released[released.count - 1] - Float(1_024 + 9_599) / 1_000_000 * gain) < 1e-6, "processed again")
    }

    @Test func theOutputLimiterHoldsTheCeiling() throws {
        let loud = directory.appending(path: "loud.caf")
        try TestMedia.writeSamples([(0..<9_600).map { $0.isMultiple(of: 2) ? 0.95 : -0.95 }], to: loud)
        let engine = try AVPlaybackEngine(manualRenderingFormat: format)
        try engine.load(audio: loud, video: nil)
        var manual = ManualSettings()
        manual.limiter.ceilingDB = -6
        engine.apply(manual)

        try engine.play()
        let samples = try renderSamples(engine, frames: 9_600)

        #expect(samples.map(abs).max()! <= echo.dsp.dbToLinear(-6) * 1.000_01)
        #expect(samples.map(abs).max()! > 0.4)
    }

    @Test func aStoppedEnginePausesWithThePlayheadKeptAndRestartsOnPlay() throws {
        let engine = try makeEngine()
        try engine.play()
        _ = try renderHeard(engine, frames: 4_800)
        _ = engine.currentTime   // the editor reads the playhead every frame

        // What the system does on a route change: stop the engine, then notify.
        engine.engine.stop()
        engine.handleConfigurationChange()

        #expect(!engine.isPlaying)
        #expect(abs(engine.currentTime - 0.1) < 0.001)
        try engine.play()
        #expect(engine.engine.isRunning)
        #expect(try renderHeard(engine, frames: 2).first == 4_800)
    }

    @Test func rangeIsClampedToTheAudio() throws {
        let engine = try makeEngine()
        engine.playbackRange = TimeRangeCodable(start: -1, duration: 10)
        #expect(engine.playbackRange == TimeRangeCodable(start: 0, duration: 2))
    }

    @Test func audioProjectsHaveNoVideoPlayer() throws {
        #expect(try makeEngine().videoPlayer == nil)
    }

    @Test func videoIsMutedAndEndsAtTheTrimEnd() async throws {
        let video = directory.appending(path: "source.mov")
        try await TestMedia.writeMovie(to: video, seconds: 2, withAudio: true)
        let engine = try AVPlaybackEngine(manualRenderingFormat: format)
        try engine.load(audio: audio, video: video)

        let player = try #require(engine.videoPlayer)
        #expect(player.isMuted)
        #expect(!player.automaticallyWaitsToMinimizeStalling)
        #expect(player.currentItem?.forwardPlaybackEndTime.seconds == 2)

        engine.playbackRange = TimeRangeCodable(start: 0.5, duration: 1)
        #expect(player.currentItem?.forwardPlaybackEndTime.seconds == 1.5)
    }

    @Test func seekingWhilePausedMovesTheVideo() async throws {
        let video = directory.appending(path: "source.mov")
        try await TestMedia.writeMovie(to: video, seconds: 2, withAudio: true)
        let engine = try AVPlaybackEngine(manualRenderingFormat: format)
        try engine.load(audio: audio, video: video)
        let player = try #require(engine.videoPlayer)

        engine.seek(to: 1.2)

        for _ in 0..<200 where abs(player.currentTime().seconds - 1.2) > 0.001 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(abs(player.currentTime().seconds - 1.2) < 0.001)
    }
}

struct VideoSyncTests {
    @Test func audibleTimeAdvancesWithHostTimeMinusLatency() {
        let audible = VideoSync.audibleTime(rendered: 10, renderedAt: 100, now: 100.02, outputLatency: 0.015)
        #expect(abs(audible - 10.005) < 1e-9)
    }

    @Test func driftBeyondTenMillisecondsNeedsResync() {
        #expect(!VideoSync.needsResync(audioTime: 5.009, videoTime: 5))
        #expect(VideoSync.needsResync(audioTime: 5.011, videoTime: 5))
        #expect(VideoSync.needsResync(audioTime: 4.989, videoTime: 5))
    }

    @Test func videoTimeIsProjectedToTheResyncStart() {
        #expect(abs(VideoSync.videoTime(at: 50.05, from: 12, now: 50, rate: 1) - 12.05) < 1e-9)
    }
}
