/// Timing rules for keeping preview audio on the video's timeline (SPEC § 6.6). Video is the master; audio is
/// rescheduled onto it when they drift apart.
enum VideoSync {
    /// Lead time for a shared start, so both the player node and `AVPlayer` are ready at the start host time.
    static let startDelay = 0.1
    /// Lead time when rescheduling audio to correct drift.
    static let resyncDelay = 0.05
    /// Drift beyond this is corrected (SPEC § 6.6).
    static let maxDrift = 0.010
    /// How often drift is measured while playing.
    static let checkInterval = Duration.milliseconds(500)

    /// The source time heard now: the time last rendered, advanced by the host time since then, minus the output
    /// latency (rendered audio reaches the ear that much later).
    static func audibleTime(rendered: Double, renderedAt renderSeconds: Double, now: Double, outputLatency: Double) -> Double {
        rendered + (now - renderSeconds) - outputLatency
    }

    static func needsResync(audioTime: Double, videoTime: Double) -> Bool {
        abs(audioTime - videoTime) > maxDrift
    }

    /// Where the video will be at `startSeconds` host time when it plays at `rate` from `videoTime` now.
    static func videoTime(at startSeconds: Double, from videoTime: Double, now: Double, rate: Double) -> Double {
        videoTime + (startSeconds - now) * rate
    }
}
