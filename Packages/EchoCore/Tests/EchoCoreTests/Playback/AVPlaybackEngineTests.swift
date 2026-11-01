import AVFoundation
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
        let frames = try render(engine, frames: 1_024)

        #expect(frames == Array(24_000..<25_024))
        #expect(abs(engine.currentTime - (0.5 + 1_024 / sampleRate)) < 0.001)
    }

    @Test func stopsAtTheTrimEndAndRestartsFromTheStart() async throws {
        let engine = try makeEngine()
        engine.playbackRange = TimeRangeCodable(start: 1, duration: 0.05)

        try engine.play()
        let played = try render(engine, frames: 8_192)
        try await waitUntilStopped(engine)

        #expect(Array(played.prefix(2_400)) == Array(48_000..<50_400))
        #expect(played.dropFirst(2_400).allSatisfy { $0 == 0 }, "silence after the range end")
        #expect(!engine.isPlaying)
        #expect(engine.currentTime == 1.05)

        try engine.play()
        #expect(try render(engine, frames: 4).first == 48_000)
    }

    @Test func seekWhilePlayingContinuesFromTheNewTime() throws {
        let engine = try makeEngine()
        try engine.play()
        _ = try render(engine, frames: 512)

        engine.seek(to: 1.5)
        let frames = try render(engine, frames: 256)

        #expect(frames == Array(72_000..<72_256))
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
        _ = try render(engine, frames: 4_800)

        engine.pause()
        #expect(!engine.isPlaying)
        #expect(abs(engine.currentTime - 0.1) < 0.001)

        try engine.play()
        #expect(try render(engine, frames: 2).first == 4_800)
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
        _ = try render(engine, frames: 4_800)

        engine.playbackRange = TimeRangeCodable(start: 0, duration: 0.15)
        let played = try render(engine, frames: 8_192)
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
        _ = try render(engine, frames: 2_400)

        engine.playbackRange = TimeRangeCodable(start: 0, duration: 0.2)
        let played = try render(engine, frames: 4_800)

        #expect(played == Array(2_400..<7_200))
        #expect(engine.isPlaying)
    }

    @Test func movingTheEndBeforeThePlayheadWhilePlayingStopsThere() throws {
        let engine = try makeEngine()
        try engine.play()
        _ = try render(engine, frames: 9_600)

        engine.playbackRange = TimeRangeCodable(start: 0, duration: 0.1)

        #expect(!engine.isPlaying)
        #expect(engine.currentTime == 0.1)
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
