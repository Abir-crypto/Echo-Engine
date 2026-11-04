@preconcurrency import ActivityKit
import EchoCore
import Foundation

/// The recording Live Activity through ActivityKit (SPEC § 13.7); the widget extension draws it. Updates go out about
/// twice a second, pausing and resuming at once. Nothing happens when the person turned Live Activities off.
@MainActor
final class LiveRecordingActivity: RecordingActivityPresenting {
    private let dateProvider: any DateProviding
    private var activity: Activity<RecordingActivityAttributes>?
    private var throttle = StatusUpdateThrottle(interval: .milliseconds(500))

    init(dateProvider: any DateProviding = SystemClock()) {
        self.dateProvider = dateProvider
    }

    func start(tint: AppTint) {
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        throttle.reset()
        let state = RecordingActivityAttributes.ContentState(timerStart: dateProvider.now, pausedAt: nil, level: 0)
        activity = try? Activity.request(
            attributes: RecordingActivityAttributes(tint: tint.rawValue), content: ActivityContent(state: state, staleDate: nil)
        )
    }

    func update(elapsedSeconds: Double, isPaused: Bool, level: Double) {
        guard let activity, throttle.shouldSend(at: .now, isPaused: isPaused) else { return }
        let now = dateProvider.now
        let state = RecordingActivityAttributes.ContentState(
            timerStart: now.addingTimeInterval(-elapsedSeconds), pausedAt: isPaused ? now : nil, level: level
        )
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    func end() {
        activity = nil
        // Also any left from a take the app didn't finish (it was killed): they would stay up to 8 hours.
        let activities = Activity<RecordingActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        Task {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
