/// Keeps the screen from locking while recording (SPEC § 13.7): on while recording, off on stop, pause or leaving the
/// Record tab. Wraps the app's idle timer.
@MainActor
public protocol IdleTimerControlling: AnyObject {
    var keepsScreenOn: Bool { get set }
}
