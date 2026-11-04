import Observation

/// Keeps analytics and crash reports in step with the person's consent (SPEC § 16): both off until the consent screen
/// is answered, then as answered, and again whenever Settings changes it.
@MainActor
public final class TelemetryConsent {
    private let consent: any ConsentStore
    private let analytics: any AnalyticsTracking
    private let crashes: any CrashReporting

    public init(consent: any ConsentStore, analytics: any AnalyticsTracking, crashes: any CrashReporting) {
        self.consent = consent
        self.analytics = analytics
        self.crashes = crashes
    }

    /// Applies the current consent now and follows its changes from then on.
    public func start() {
        apply()
        follow()
    }

    private func follow() {
        withObservationTracking {
            _ = (consent.hasAnswered, consent.sharesAnalytics, consent.sharesCrashReports)
        } onChange: { [weak self] in
            // Called before the change lands: apply on the next turn, then keep following.
            Task { @MainActor in
                self?.apply()
                self?.follow()
            }
        }
    }

    private func apply() {
        analytics.setEnabled(consent.hasAnswered && consent.sharesAnalytics)
        crashes.setEnabled(consent.hasAnswered && consent.sharesCrashReports)
    }
}
