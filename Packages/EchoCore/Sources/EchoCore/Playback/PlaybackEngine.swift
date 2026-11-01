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
    /// Switches to `audio` (same format and length, e.g. a finished AI render or `working.caf` while holding for the
    /// original) at the playhead with a 20 ms crossfade (SPEC § 6.3); while paused, the next `play` uses it.
    func swapAudio(to audio: URL) throws
    /// Plays from the playhead; from the range start when the playhead is at the range end.
    func play() throws
    func pause()
    /// Moves the playhead, clamped to `playbackRange`; keeps playing if playing.
    func seek(to time: Double)
    /// Sets the live manual chain and the output limiter (SPEC § 8) through their parameters; changes ramp, so this
    /// can be called on every slider step.
    func apply(_ manual: ManualSettings)
    /// Auto Level's static gain in dB (SPEC § 6.7), applied before the output limiter; ramps to the new value.
    func setAutoLevelGain(_ gainDB: Double)
    /// "Hold for original" (SPEC § 6.6): while held, the chain and limiter are bypassed with a short crossfade; the
    /// timing doesn't change.
    func holdOriginal(_ isHolding: Bool)
}
