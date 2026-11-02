import EchoCore

/// Records activities instead of asking the system; can refuse background time.
@MainActor
public final class FakeBackgroundProcessing: BackgroundProcessing {
    public var allowsBackground = true
    public private(set) var activities: [FakeBackgroundActivity] = []
    /// Runs when an activity finishes, with its result.
    public var onActivityFinished: (@MainActor (Bool) -> Void)?

    public init() {}

    public func begin(title: String, subtitle: String, onStop: @escaping @MainActor () -> Void) -> (any BackgroundActivity)? {
        guard allowsBackground else { return nil }
        let activity = FakeBackgroundActivity(title: title, subtitle: subtitle, onStop: onStop) { [weak self] success in
            self?.onActivityFinished?(success)
        }
        activities.append(activity)
        return activity
    }
}

@MainActor
public final class FakeBackgroundActivity: BackgroundActivity {
    public let title: String
    public let subtitle: String
    public private(set) var progress: [Double] = []
    /// `nil` while running.
    public private(set) var result: Bool?
    private let onStop: @MainActor () -> Void
    private let onFinish: @MainActor (Bool) -> Void

    init(title: String, subtitle: String, onStop: @escaping @MainActor () -> Void, onFinish: @escaping @MainActor (Bool) -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.onStop = onStop
        self.onFinish = onFinish
    }

    public func report(progress: Double) {
        guard result == nil else { return }
        self.progress.append(progress)
    }

    public func finish(success: Bool) {
        guard result == nil else { return }
        result = success
        onFinish(success)
    }

    /// What the system does when it, or the person in its progress UI, stops the task.
    public func stop() {
        guard result == nil else { return }
        result = false
        onStop()
    }
}
