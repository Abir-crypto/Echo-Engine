import AVFoundation
import CEchoDSP
import EchoAudioUnits
import Observation

/// `AVAudioEngine` preview: player node → manual chain → (Auto Level gain, F07) → output limiter → main mixer, plus a
/// muted `AVPlayer` for video projects (SPEC § 6.6).
///
/// The trim range is played with `scheduleSegment`, followed by silence as long as the chain's latency so its tail
/// is heard; seeking reschedules from the new frame and clears the chain. Every schedule gets a generation number so
/// completion callbacks from schedules stopped by a seek or pause are ignored. The playhead is what leaves the chain.
/// With video, both start from a shared host time (audio earlier by the chain and output latency), and audio is
/// rescheduled onto the video's timeline when they drift apart.
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
            if !playbackRange.contains(currentTime) {
                seek(to: playbackRange.start)
            } else if isPlaying, rangeEndFrame != scheduledEndFrame {
                // The playing segment still ends at the old range end.
                seek(to: currentTime)
            }
        }
    }

    /// Internal for tests that simulate the system stopping it.
    @ObservationIgnored let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private let manualChain: AVAudioUnitEffect
    @ObservationIgnored private let outputLimiter: AVAudioUnitEffect
    @ObservationIgnored private let isOffline: Bool
    @ObservationIgnored private var file: AVAudioFile?
    /// Source seconds where the current schedule starts.
    @ObservationIgnored private var segmentStart: Double = 0
    /// Where the current schedule ends, so a moved range end can be rescheduled.
    @ObservationIgnored private var scheduledEndFrame: AVAudioFramePosition = 0
    /// Observed, so seeking while paused updates the UI; while playing, `currentTime` reads the player node.
    private var pausedTime: Double = 0
    /// Host seconds at which `segmentStart` leaves the chain; estimates the playhead when the stopped engine has no
    /// render time.
    @ObservationIgnored private var segmentStartHostSeconds: Double = 0
    @ObservationIgnored private var lastRendered: (time: Double, hostSeconds: Double, generation: Int)?
    @ObservationIgnored private var appliedChainValues: [AUParameterAddress: AUValue] = [:]
    @ObservationIgnored private var appliedCeiling: Float?
    @ObservationIgnored private var configurationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var cachedFlush: AVAudioPCMBuffer?
    @ObservationIgnored private var driftTask: Task<Void, Never>?

    public init() {
        isOffline = false
        (manualChain, outputLimiter) = Self.makeEffects()
        attachNodes()
        observeConfigurationChanges()
    }

    /// Renders offline instead of to the hardware, for tests (`renderOffline(frames:)`). Video never plays here.
    init(manualRenderingFormat format: AVAudioFormat) throws {
        isOffline = true
        (manualChain, outputLimiter) = Self.makeEffects()
        attachNodes()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        observeConfigurationChanges()
    }

    isolated deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    /// The system stops the engine when the output's format changes (a route change such as unplugged headphones).
    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    /// Pauses with the playhead kept; the next `play` restarts the engine.
    func handleConfigurationChange() {
        pause()
    }

    private static func makeEffects() -> (AVAudioUnitEffect, AVAudioUnitEffect) {
        EchoAudioUnits.register()
        return (
            AVAudioUnitEffect(audioComponentDescription: ManualChainAudioUnit.componentDescription),
            AVAudioUnitEffect(audioComponentDescription: OutputLimiterAudioUnit.componentDescription)
        )
    }

    private func attachNodes() {
        for node in [player, manualChain, outputLimiter] {
            engine.attach(node)
        }
    }

    private var effectUnits: [EchoEffectAudioUnit] {
        [manualChain, outputLimiter].compactMap { $0.auAudioUnit as? EchoEffectAudioUnit }
    }

    /// Frames the chain delays audio by (pitch shift look-ahead + limiter look-ahead); valid while the engine runs.
    var chainLatencyFrames: Int {
        effectUnits.reduce(0) { $0 + $1.latencyFrames }
    }

    public var currentTime: Double {
        guard isPlaying else { return pausedTime }
        if let rendered = renderedTime {
            lastRendered = (rendered.time, rendered.hostSeconds, generation)
            return min(playbackRange.end, rendered.time)
        }
        // A stopped engine (route change, interruption) has no render time: continue from the last one the editor
        // read (it reads every frame), else from the schedule's start, by the clock (offline renders have none).
        let elapsed: (Double) -> Double = { [isOffline] since in isOffline ? 0 : max(0, Self.now() - since) }
        if let lastRendered, lastRendered.generation == generation {
            return min(playbackRange.end, lastRendered.time + elapsed(lastRendered.hostSeconds))
        }
        return min(playbackRange.end, segmentStart + elapsed(segmentStartHostSeconds))
    }

    public func load(audio url: URL, video videoURL: URL?) throws {
        let file = try AVAudioFile(forReading: url)
        stopPlayback()
        let format = file.processingFormat
        if self.file?.processingFormat != format {
            if engine.isRunning { engine.stop() }
            for node in [player, manualChain, outputLimiter] {
                engine.disconnectNodeOutput(node)
            }
            engine.connect(player, to: manualChain, format: format)
            engine.connect(manualChain, to: outputLimiter, format: format)
            engine.connect(outputLimiter, to: engine.mainMixerNode, format: format)
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
        guard file != nil, !isPlaying, playbackRange.duration > 0 else { return }
        if isAtEnd(pausedTime) {
            pausedTime = playbackRange.start
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        guard schedule(from: pausedTime) else { return }
        if let video = videoPlayer, !isOffline {
            // Start both from one host time; audio starts earlier by the output latency so what is heard matches
            // what is shown.
            let start = Self.now() + VideoSync.startDelay
            player.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: start - outputLatency - chainLatency)))
            segmentStartHostSeconds = start
            video.setRate(1, time: Self.cmTime(pausedTime), atHostTime: Self.cmHostTime(start))
            startDriftCorrection()
        } else {
            player.play()
            segmentStartHostSeconds = Self.now() + chainLatency
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
        if isAtEnd(target) {
            finishAtEnd()
        } else if videoPlayer != nil, !isOffline {
            stopPlayback()
            pausedTime = target
            try? play()
        } else {
            stopPlayer()
            if schedule(from: target) {
                player.play()
                segmentStartHostSeconds = Self.now() + chainLatency
            } else {
                finishAtEnd()
            }
        }
    }

    public func apply(_ manual: ManualSettings) {
        // Sliders call this on every step; only changed parameters are sent.
        if let tree = manualChain.auAudioUnit.parameterTree {
            for (address, value) in manual.manualChainParameterValues where appliedChainValues[address] != value {
                tree.parameter(withAddress: address)?.value = value
                appliedChainValues[address] = value
            }
        }
        if appliedCeiling != manual.limiter.ceilingDB {
            outputLimiter.auAudioUnit.parameterTree?
                .parameter(withAddress: EEOutputLimiterParameter.ceiling.rawValue)?.value = manual.limiter.ceilingDB
            appliedCeiling = manual.limiter.ceilingDB
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

    /// Schedules `time`…range end; `false` when nothing is left to play.
    @discardableResult
    private func schedule(from time: Double) -> Bool {
        guard let file else { return false }
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition((time * sampleRate).rounded())
        let endFrame = rangeEndFrame
        segmentStart = Double(startFrame) / sampleRate
        pausedTime = segmentStart
        scheduledEndFrame = endFrame
        guard endFrame > startFrame else { return false }
        generation += 1
        let scheduled = generation
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(endFrame - startFrame), at: nil)
        // Silence pushes the range's last frames out of the chain. `.dataRendered`, not `.dataPlayedBack`: the latter
        // never fires in offline rendering (tests), and stopping once rendered can't cut audio already on its way out.
        player.scheduleBuffer(flushBuffer(for: file.processingFormat), at: nil, completionCallbackType: .dataRendered) { [weak self] _ in
            Task { @MainActor in self?.segmentFinished(scheduled) }
        }
        return true
    }

    private func segmentFinished(_ scheduled: Int) {
        guard scheduled == generation, isPlaying else { return }
        finishAtEnd()
    }

    /// The range end was reached: stop with the playhead at the end; the next `play` restarts at the range start.
    private func finishAtEnd() {
        stopPlayback()
        pausedTime = playbackRange.end
        seekVideo(to: pausedTime)
    }

    /// The last frame of the range, in file frames.
    private var rangeEndFrame: AVAudioFramePosition {
        guard let file else { return 0 }
        return min(file.length, AVAudioFramePosition((playbackRange.end * file.processingFormat.sampleRate).rounded()))
    }

    /// Less than one frame of the range is left after `time`.
    private func isAtEnd(_ time: Double) -> Bool {
        guard let file else { return true }
        return time >= playbackRange.end - 1 / file.processingFormat.sampleRate
    }

    private func stopPlayback() {
        stopPlayer()
        videoPlayer?.pause()
        driftTask?.cancel()
        driftTask = nil
        isPlaying = false
    }

    /// Stops the player node and clears the chain; pending completion callbacks become stale.
    private func stopPlayer() {
        generation += 1
        player.stop()
        effectUnits.forEach { $0.requestReset() }
    }

    /// Chain-latency frames of silence (at least one), reused while the format and latency stay the same.
    private func flushBuffer(for format: AVAudioFormat) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(max(1, chainLatencyFrames))
        if let cachedFlush, cachedFlush.format == format, cachedFlush.frameLength == frames {
            return cachedFlush
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        cachedFlush = buffer
        return buffer
    }

    /// The source time that last left the chain, and the host time (seconds) it was rendered at.
    private var renderedTime: (time: Double, hostSeconds: Double)? {
        guard let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return nil
        }
        let frames = max(0, Double(playerTime.sampleTime) - Double(chainLatencyFrames))
        let time = segmentStart + frames / playerTime.sampleRate
        return (time, nodeTime.isHostTimeValid ? AVAudioTime.seconds(forHostTime: nodeTime.hostTime) : Self.now())
    }

    /// Hardware output latency: rendered audio is heard this much later.
    private var outputLatency: Double {
        engine.outputNode.presentationLatency
    }

    private var chainLatency: Double {
        guard let file else { return 0 }
        return Double(chainLatencyFrames) / file.processingFormat.sampleRate
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
        videoPlayer?.currentItem?.forwardPlaybackEndTime = Self.cmTime(playbackRange.end)
    }

    private func seekVideo(to time: Double) {
        videoPlayer?.seek(to: Self.cmTime(time), toleranceBefore: .zero, toleranceAfter: .zero)
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
        guard schedule(from: VideoSync.videoTime(at: start, from: videoNow, now: now, rate: Double(video.rate))) else {
            finishAtEnd()
            return
        }
        player.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: start - outputLatency - chainLatency)))
        segmentStartHostSeconds = start
    }

    // MARK: Time

    private static func now() -> Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    private static func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 48_000)
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
