import AVFoundation
import Observation

/// Real-time preview of a project's audio (SPEC § 6.6): AI render (or `working.caf`) → live manual chain →
/// output, limited to the trim range, with video kept in sync.
@MainActor
public protocol PlaybackEngine: AnyObject, Observable {
    /// Seconds of the loaded audio; 0 before `load`.
    var duration: Double { get }
    /// Playback is limited to this range (the project's `trimRange`), clamped to the audio.
    var playbackRange: TimeRangeCodable { get set }
    var isPlaying: Bool { get }
    /// Playhead in source seconds. Not observed: read it on every frame while playing (e.g. `TimelineView`).
    var currentTime: Double { get }
    /// The muted player behind `VideoPreview`; `nil` for audio projects.
    var videoPlayer: AVPlayer? { get }

    /// Loads the audio to play (`working.caf` or an AI render) and, for video projects, the source video. Keeps the
    /// playhead where possible. Stops playback.
    func load(audio: URL, video: URL?) throws
    /// Plays from the playhead; from the range start when the playhead is at the range end.
    func play() throws
    func pause()
    /// Moves the playhead, clamped to `playbackRange`; keeps playing if playing.
    func seek(to time: Double)
}
