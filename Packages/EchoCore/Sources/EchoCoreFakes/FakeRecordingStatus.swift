import EchoCore

/// Records what the recording's Live Activity would show.
@MainActor
public final class FakeRecordingActivity: RecordingActivityPresenting {
    public struct Update: Equatable, Sendable {
        public let elapsedSeconds: Double
        public let isPaused: Bool
        public let level: Double
    }

    public private(set) var tint: AppTint?
    public private(set) var isShown = false
    public private(set) var updates: [Update] = []
    public private(set) var endCount = 0

    public init() {}

    public func start(tint: AppTint) {
        self.tint = tint
        isShown = true
    }

    public func update(elapsedSeconds: Double, isPaused: Bool, level: Double) {
        updates.append(Update(elapsedSeconds: elapsedSeconds, isPaused: isPaused, level: level))
    }

    public func end() {
        isShown = false
        endCount += 1
    }
}

@MainActor
public final class FakeIdleTimer: IdleTimerControlling {
    public var keepsScreenOn = false

    public init() {}
}
