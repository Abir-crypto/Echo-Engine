import ActivityKit
import Foundation

/// The recording Live Activity (SPEC § 13.7): status, timer, level and Stop on the Lock Screen and in the Dynamic
/// Island. Shared by the app (which starts and updates it) and the widget extension (which draws it). Carries no
/// title or other user content.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// When the take would have started had it never paused: the timer counts up from here.
        var timerStart: Date
        /// Set while paused (by the person or an interruption): the timer stands at the time recorded until then.
        var pausedAt: Date?
        /// The loudest recorded channel, 0…1 on the meter's scale (`MeterScale`).
        var level: Double

        var isPaused: Bool { pausedAt != nil }
    }

    /// The person's tint (`AppTint` raw value), so the meter matches the Record screen.
    var tint: String
}
