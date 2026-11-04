/// The recording's status outside the app (SPEC § 13.7): a Live Activity on the Lock Screen and in the Dynamic Island
/// with the timer, the level and Stop. Shows no title or other user content.
@MainActor
public protocol RecordingActivityPresenting: AnyObject {
    /// Shows the status for a take that just started, its meter in `tint`.
    func start(tint: AppTint)
    /// The take's recorded time, whether it is paused and the loudest channel's meter position (0…1). Call as often
    /// as the meters update; implementations send about two updates a second.
    func update(elapsedSeconds: Double, isPaused: Bool, level: Double)
    /// Removes the status, and any left from a take the app didn't finish (it was killed).
    func end()
}

/// Lets status updates through at most once per `interval`, except that pausing or resuming goes out at once.
public struct StatusUpdateThrottle: Sendable {
    public let interval: Duration
    private var lastSent: ContinuousClock.Instant?
    private var lastIsPaused: Bool?

    public init(interval: Duration) {
        self.interval = interval
    }

    public mutating func shouldSend(at now: ContinuousClock.Instant, isPaused: Bool) -> Bool {
        if let lastSent, lastIsPaused == isPaused, now - lastSent < interval { return false }
        lastSent = now
        lastIsPaused = isPaused
        return true
    }

    /// The next update goes out whatever the time.
    public mutating func reset() {
        lastSent = nil
        lastIsPaused = nil
    }
}
