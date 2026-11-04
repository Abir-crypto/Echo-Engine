import EchoCore

/// Remembers what would have been sent, and whether collection was on.
@MainActor
public final class FakeAnalytics: AnalyticsTracking {
    public private(set) var events: [AnalyticsEvent] = []
    public private(set) var isEnabled = false

    public init() {}

    public func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    public func track(_ event: AnalyticsEvent) {
        events.append(event)
    }
}

@MainActor
public final class FakeCrashReporter: CrashReporting {
    public private(set) var isEnabled = false
    public private(set) var context: [CrashContextKey: String] = [:]
    public private(set) var logs: [String] = []
    public private(set) var errors: [String] = []

    public init() {}

    public func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    public func setContext(_ key: CrashContextKey, _ value: String) {
        context[key] = value
    }

    public func log(_ message: StaticString) {
        logs.append("\(message)")
    }

    public func record(_ error: any Error) {
        errors.append(String(describing: type(of: error)))
    }
}
