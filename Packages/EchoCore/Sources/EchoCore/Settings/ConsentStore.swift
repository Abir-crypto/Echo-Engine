import Foundation
import Observation

/// Consent to analytics and crash reports (SPEC § 4.3, § 16): asked once before anything is collected, changeable in
/// Settings. Until the person answers, both are off.
@MainActor
public protocol ConsentStore: AnyObject, Observable {
    var sharesAnalytics: Bool { get set }
    var sharesCrashReports: Bool { get set }
    /// The consent screen was answered (F14); before that nothing is collected and the screen shows.
    var hasAnswered: Bool { get }
    func recordAnswer(analytics: Bool, crashReports: Bool)
}

@MainActor
@Observable
public final class UserDefaultsConsentStore: ConsentStore {
    private static let analyticsKey = "consent.analytics"
    private static let crashReportsKey = "consent.crashReports"
    private static let answeredKey = "consent.answered"
    @ObservationIgnored private let defaults: UserDefaults

    public var sharesAnalytics: Bool {
        didSet { defaults.set(sharesAnalytics, forKey: Self.analyticsKey) }
    }

    public var sharesCrashReports: Bool {
        didSet { defaults.set(sharesCrashReports, forKey: Self.crashReportsKey) }
    }

    public private(set) var hasAnswered: Bool {
        didSet { defaults.set(hasAnswered, forKey: Self.answeredKey) }
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        sharesAnalytics = defaults.bool(forKey: Self.analyticsKey)
        sharesCrashReports = defaults.bool(forKey: Self.crashReportsKey)
        hasAnswered = defaults.bool(forKey: Self.answeredKey)
    }

    public func recordAnswer(analytics: Bool, crashReports: Bool) {
        sharesAnalytics = analytics
        sharesCrashReports = crashReports
        hasAnswered = true
    }
}
