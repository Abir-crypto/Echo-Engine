/// Product analytics behind consent (SPEC § 4.3, § 16). Nothing else in the app talks to the analytics service.
@MainActor
public protocol AnalyticsTracking: AnyObject {
    /// Collection on or off, following the person's consent.
    func setEnabled(_ isEnabled: Bool)
    func track(_ event: AnalyticsEvent)
}

/// Crash reports behind consent (SPEC § 4.3, § 4.7, § 16). Context, logs and errors never carry user content.
@MainActor
public protocol CrashReporting: AnyObject {
    func setEnabled(_ isEnabled: Bool)
    func setContext(_ key: CrashContextKey, _ value: String)
    /// A breadcrumb: fixed wording only, never titles, names or paths.
    func log(_ message: StaticString)
    /// A handled error, by type and case only.
    func record(_ error: any Error)
}

/// Crash context keys (SPEC § 16).
public enum CrashContextKey: String, Sendable {
    case screen
    /// The AI stack's kinds, e.g. "noiseSuppression,clearVoice".
    case aiStack = "ai_stack"
    case recordingState = "recording_state"
    case inputType = "input_type"
    case mediaType = "media_type"
    case durationBucket = "duration_bucket"
    case sourceContainer = "source_container"
}

/// Used until Firebase is configured, or in tests and previews: drops everything.
@MainActor
public final class NoOpAnalytics: AnalyticsTracking {
    public init() {}
    public func setEnabled(_ isEnabled: Bool) {}
    public func track(_ event: AnalyticsEvent) {}
}

@MainActor
public final class NoOpCrashReporter: CrashReporting {
    public init() {}
    public func setEnabled(_ isEnabled: Bool) {}
    public func setContext(_ key: CrashContextKey, _ value: String) {}
    public func log(_ message: StaticString) {}
    public func record(_ error: any Error) {}
}
