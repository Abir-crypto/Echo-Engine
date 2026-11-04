import EchoCore
import Observation

@MainActor
@Observable
public final class FakeConsentStore: ConsentStore {
    public var sharesAnalytics: Bool
    public var sharesCrashReports: Bool
    public private(set) var hasAnswered: Bool

    public init(analytics: Bool = false, crashReports: Bool = false, hasAnswered: Bool = false) {
        sharesAnalytics = analytics
        sharesCrashReports = crashReports
        self.hasAnswered = hasAnswered
    }

    public func recordAnswer(analytics: Bool, crashReports: Bool) {
        sharesAnalytics = analytics
        sharesCrashReports = crashReports
        hasAnswered = true
    }
}
