import EchoCore
import Observation

/// The first-launch consent screen (SPEC § 16): both switches start off; nothing is collected until Continue.
@MainActor
@Observable
final class ConsentModel {
    var sharesAnalytics = false
    var sharesCrashReports = false

    @ObservationIgnored private let consent: any ConsentStore
    @ObservationIgnored private let telemetry: TelemetryConsent
    @ObservationIgnored private let analytics: any AnalyticsTracking

    init(consent: any ConsentStore, telemetry: TelemetryConsent, analytics: any AnalyticsTracking) {
        self.consent = consent
        self.telemetry = telemetry
        self.analytics = analytics
    }

    /// Records the answer and applies it now, so the answer itself is counted only when analytics was allowed.
    func finish() {
        consent.recordAnswer(analytics: sharesAnalytics, crashReports: sharesCrashReports)
        telemetry.apply()
        analytics.track(.onboardingCompleted(analytics: sharesAnalytics, crash: sharesCrashReports))
    }
}
