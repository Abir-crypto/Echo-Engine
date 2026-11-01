import AVFoundation
import Observation

/// `AVAudioEngine` preview: player node → chain input → main mixer → output, plus a muted `AVPlayer` for video
/// projects (SPEC § 6.6).
///
/// The trim range is played with `scheduleSegment`; seeking reschedules from the new frame. Every schedule gets a
/// generation number so completion callbacks from segments stopped by a seek or pause are ignored. With video,
/// both start from a shared host time, and audio is rescheduled onto the video's timeline when they drift apart.
@MainActor
@Observable
public final class AVPlaybackEngine: PlaybackEngine {
    public private(set) var duration: Double = 0
    public private(set) var isPlaying = false
    public private(set) var videoPlayer: AVPlayer?

    public var playbackRange = TimeRangeCodable(start: 0, duration: 0) {
        didSet {
            let clamped = clamp(playbackRange)
            if clamped != playbackRange { playbackRange = clamped; return }
            updateVideoEnd()
            if !playbackRange.contains(currentTime) { seek(to: playbackRange.start) }
        }
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    /// Where the manual chain (F05), Auto Level gain and limiter (F07) are inserted.
    @ObservationIgnored private let chainInput = AVAudioMixerNode()
    @ObservationIgnored private let isOffline: Bool
    @ObservationIgnored private var file: AVAudioFile?
    /// Source seconds where the current schedule starts.
    @ObservationIgnored private var segmentStart: Double = 0
    /// Observed, so seeking while paused updates the UI; while playing, `currentTime` reads the player node.
    private var pausedTime: Double = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var driftTask: Task<Void, Never>?

    public init() {
        isOffline = false
        engine.attach(player)
        engine.attach(chainInput)
    }

    /// Renders offline instead of to the hardware, for tests (`renderOffline(frames:)`). Video never plays here.
    init(manualRenderingFormat format: AVAudioFormat) throws {
        isOffline = true
        engine.attach(player)
        engine.attach(chainInput)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
    }

    public var currentTime: Double {
        guard isPlaying, let rendered = renderedTime else { return pausedTime }
        return min(playbackRange.end, rendered.time)
    }

    public func load(audio url: URL, video videoURL: URL?) throws {
        let file = try AVAudioFile(forReading: url)
        stopPlayback()
        let format = file.processingFormat
        if self.file?.processingFormat != format {
            if engine.isRunning { engine.stop() }
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(chainInput)
            engine.connect(player, to: chainInput, format: format)
            engine.connect(chainInput, to: engine.mainMixerNode, format: format)
        }
        self.file = file
        duration = Double(file.length) / format.sampleRate
        videoPlayer = videoURL.map(Self.makeVideoPlayer)
        let wasEmpty = playbackRange.duration == 0
        playbackRange = wasEmpty ? .full(duration: duration) : playbackRange
        updateVideoEnd()
        pausedTime = min(max(pausedTime, playbackRange.start), playbackRange.end)
        seekVideo(to: pausedTime)
    }

    public func play() throws {
        guard let file, !isPlaying, playbackRange.duration > 0 else { return }
        if pausedTime >= playbackRange.end - 1 / file.processingFormat.sampleRate {
            pausedTime = playbackRange.start
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        schedule(from: pausedTime)
        if let video = videoPlayer, !isOffline {
            // Start both from one host time; audio starts earlier by the output latency so what is heard matches
            // what is shown.
            let start = Self.now() + VideoSync.startDelay
            player.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: start - outputLatency)))
            video.setRate(1, time: CMTime(seconds: pausedTime, preferredTimescale: 48_000), atHostTime: Self.cmHostTime(start))
            startDriftCorrection()
        } else {
            player.play()
        }
        isPlaying = true
    }

    public func pause() {
        guard isPlaying else { return }
        let time = currentTime
        stopPlayback()
        pausedTime = time
        seekVideo(to: time)
    }

    public func seek(to time: Double) {
        let target = min(max(time, playbackRange.start), playbackRange.end)
        guard isPlaying else {
            pausedTime = target
            seekVideo(to: target)
            return
        }
        if videoPlayer != nil, !isOffline {
            stopPlayback()
            pausedTime = target
            try? play()
        } else {
            stopPlayer()
            schedule(from: target)
            player.play()
        }
    }

    /// Renders `frames` frames in manual rendering mode (tests only).
    func renderOffline(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames) else {
            throw PlaybackError.renderFailed
        }
        guard try engine.renderOffline(frames, to: buffer) == .success else { throw PlaybackError.renderFailed }
        return buffer
    }

    // MARK: Scheduling

    private func schedule(from time: Double) {
        guard let file else { return }
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition((time * sampleRate).rounded())
        let endFrame = min(file.length, AVAudioFramePosition((playbackRange.end * sampleRate).rounded()))
        segmentStart = Double(startFrame) / sampleRate
        pausedTime = segmentStart
        guard endFrame > startFrame else { return }
        generation += 1
        let scheduled = generation
        // `.dataRendered`, not `.dataPlayedBack`: the latter never fires in offline rendering (tests), and stopping the
        // player once the last frame is rendered can't cut audio that is already on its way to the output.
        player.scheduleSegment(
            file, startingFrame: startFrame, frameCount: AVAudioFrameCount(endFrame - startFrame), at: nil,
            completionCallbackType: .dataRendered
        ) { [weak self] _ in
            Task { @MainActor in self?.segmentFinished(scheduled) }
        }
    }

    /// The range end was reached: stop with the playhead at the end; the next `play` restarts at the range start.
    private func segmentFinished(_ scheduled: Int) {
        guard scheduled == generation, isPlaying else { return }
        stopPlayback()
        pausedTime = playbackRange.end
    }

    private func stopPlayback() {
        stopPlayer()
        videoPlayer?.pause()
        driftTask?.cancel()
        driftTask = nil
        isPlaying = false
    }

    /// Stops the player node; its pending completion callbacks become stale.
    private func stopPlayer() {
        generation += 1
        player.stop()
    }

    /// The source time last rendered by the player node, and the host time (seconds) it was rendered at.
    private var renderedTime: (time: Double, hostSeconds: Double)? {
        guard let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return nil
        }
        let time = segmentStart + max(0, Double(playerTime.sampleTime) / playerTime.sampleRate)
        return (time, nodeTime.isHostTimeValid ? AVAudioTime.seconds(forHostTime: nodeTime.hostTime) : Self.now())
    }

    private var outputLatency: Double {
        engine.outputNode.presentationLatency
    }

    // MARK: Video

    private static func makeVideoPlayer(_ url: URL) -> AVPlayer {
        let player = AVPlayer(playerItem: AVPlayerItem(url: url))
        player.isMuted = true
        // Required for `setRate(_:time:atHostTime:)`.
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        return player
    }

    private func updateVideoEnd() {
        videoPlayer?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: playbackRange.end, preferredTimescale: 48_000)
    }

    private func seekVideo(to time: Double) {
        videoPlayer?.seek(
            to: CMTime(seconds: time, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero
        )
    }

    private func startDriftCorrection() {
        driftTask?.cancel()
        driftTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: VideoSync.checkInterval)
                guard let self, self.isPlaying, !Task.isCancelled else { return }
                self.correctDrift()
            }
        }
    }

    /// Reschedules audio onto the video's timeline when the audible audio is more than `VideoSync.maxDrift` off.
    private func correctDrift() {
        guard let video = videoPlayer, video.rate > 0, let rendered = renderedTime else { return }
        let now = Self.now()
        let audible = VideoSync.audibleTime(
            rendered: rendered.time, renderedAt: rendered.hostSeconds, now: now, outputLatency: outputLatency
        )
        let videoNow = video.currentTime().seconds
        guard VideoSync.needsResync(audioTime: audible, videoTime: videoNow) else { return }
        let start = now + VideoSync.resyncDelay
        stopPlayer()
        schedule(from: VideoSync.videoTime(at: start, from: videoNow, now: now, rate: Double(video.rate)))
        player.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: start - outputLatency)))
    }

    // MARK: Time

    private static func now() -> Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    private static func cmHostTime(_ seconds: Double) -> CMTime {
        CMClockMakeHostTimeFromSystemUnits(AVAudioTime.hostTime(forSeconds: seconds))
    }

    private func clamp(_ range: TimeRangeCodable) -> TimeRangeCodable {
        guard duration > 0 else { return range }
        let start = min(max(range.start, 0), duration)
        let end = min(max(range.end, start), duration)
        return TimeRangeCodable(start: start, duration: end - start)
    }
}

public enum PlaybackError: Error, Equatable {
    case renderFailed
}

extension TimeRangeCodable {
    public func contains(_ time: Double) -> Bool {
        time >= start && time <= end
    }
}
