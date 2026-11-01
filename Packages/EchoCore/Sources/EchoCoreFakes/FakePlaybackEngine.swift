import AVFoundation
import EchoCore
import Observation

/// Plays nothing: records what was loaded and keeps the playhead where `seek` puts it.
@MainActor
@Observable
public final class FakePlaybackEngine: PlaybackEngine {
    public var duration: Double
    public var playbackRange = TimeRangeCodable(start: 0, duration: 0)
    public private(set) var isPlaying = false
    public var currentTime: Double = 0
    public private(set) var videoPlayer: AVPlayer?
    public private(set) var loadedAudio: URL?
    public private(set) var loadedVideo: URL?
    /// The last settings passed to `apply`.
    public private(set) var appliedManual: ManualSettings?
    public private(set) var isHoldingOriginal = false
    public private(set) var autoLevelGainDB: Double = 0
    @ObservationIgnored public var loadError: (any Error)?

    public init(duration: Double = 60) {
        self.duration = duration
    }

    public func load(audio: URL, video: URL?) throws {
        if let loadError { throw loadError }
        loadedAudio = audio
        loadedVideo = video
        swappedAudio.removeAll()
        isPlaying = false
        if playbackRange.duration == 0 {
            playbackRange = .full(duration: duration)
        }
    }

    /// Every `swapAudio` target, in order.
    public private(set) var swappedAudio: [URL] = []
    /// What is playing: the last loaded or swapped-in audio.
    public var currentAudio: URL? { swappedAudio.last ?? loadedAudio }

    public func swapAudio(to audio: URL) throws {
        if let loadError { throw loadError }
        swappedAudio.append(audio)
    }

    public func play() throws {
        isPlaying = true
    }

    public func pause() {
        isPlaying = false
    }

    public func seek(to time: Double) {
        currentTime = min(max(time, playbackRange.start), playbackRange.end)
    }

    public func apply(_ manual: ManualSettings) {
        appliedManual = manual
    }

    public func setAutoLevelGain(_ gainDB: Double) {
        autoLevelGainDB = gainDB
    }

    public func holdOriginal(_ isHolding: Bool) {
        isHoldingOriginal = isHolding
    }
}
