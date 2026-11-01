import AVFoundation
import Observation

/// `AVAudioEngine` preview: player node → chain input → main mixer → output (SPEC § 6.6).
///
/// The trim range is played with `scheduleSegment`; seeking reschedules from the new frame. Every schedule gets a
/// generation number so completion callbacks from segments stopped by a seek or pause are ignored.
@MainActor
@Observable
public final class AVPlaybackEngine: PlaybackEngine {
    public private(set) var duration: Double = 0
    public private(set) var isPlaying = false

    public var playbackRange = TimeRangeCodable(start: 0, duration: 0) {
        didSet {
            let clamped = clamp(playbackRange)
            if clamped != playbackRange { playbackRange = clamped; return }
            if !playbackRange.contains(currentTime) { seek(to: playbackRange.start) }
        }
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    /// Where the manual chain (F05), Auto Level gain and limiter (F07) are inserted.
    @ObservationIgnored private let chainInput = AVAudioMixerNode()
    @ObservationIgnored private var file: AVAudioFile?
    /// Source seconds where the current schedule starts.
    @ObservationIgnored private var segmentStart: Double = 0
    @ObservationIgnored private var pausedTime: Double = 0
    @ObservationIgnored private var generation = 0

    public init() {
        engine.attach(player)
        engine.attach(chainInput)
    }

    /// Renders offline instead of to the hardware, for tests (`renderOffline(frames:)`).
    init(manualRenderingFormat format: AVAudioFormat) throws {
        engine.attach(player)
        engine.attach(chainInput)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
    }

    public var currentTime: Double {
        guard isPlaying,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return pausedTime }
        let played = Double(playerTime.sampleTime) / playerTime.sampleRate
        return min(playbackRange.end, segmentStart + max(0, played))
    }

    public func load(audio url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        stopPlayer()
        isPlaying = false
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
        let wasEmpty = playbackRange.duration == 0
        playbackRange = wasEmpty ? .full(duration: duration) : playbackRange
        pausedTime = min(max(pausedTime, playbackRange.start), playbackRange.end)
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
        player.play()
        isPlaying = true
    }

    public func pause() {
        guard isPlaying else { return }
        pausedTime = currentTime
        stopPlayer()
        isPlaying = false
    }

    public func seek(to time: Double) {
        let target = min(max(time, playbackRange.start), playbackRange.end)
        if isPlaying {
            stopPlayer()
            schedule(from: target)
            player.play()
        } else {
            pausedTime = target
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
        stopPlayer()
        isPlaying = false
        pausedTime = playbackRange.end
    }

    /// Stops the player node; its pending completion callbacks become stale.
    private func stopPlayer() {
        generation += 1
        player.stop()
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
