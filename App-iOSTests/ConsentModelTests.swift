import EchoCore
import EchoCoreFakes
@testable import EchoEngine
import Testing

/// The first-launch consent screen (SPEC § 16).
@MainActor
struct ConsentModelTests {
    private let consent = FakeConsentStore()
    private let analytics = FakeAnalytics()
    private let crashes = FakeCrashReporter()

    private func makeModel() -> ConsentModel {
        let telemetry = TelemetryConsent(consent: consent, analytics: analytics, crashes: crashes)
        telemetry.start()
        return ConsentModel(consent: consent, telemetry: telemetry, analytics: analytics)
    }

    @Test func bothSwitchesStartOffAndNothingIsCollectedBeforeContinue() {
        let model = makeModel()
        #expect(!model.sharesAnalytics)
        #expect(!model.sharesCrashReports)
        model.sharesAnalytics = true
        #expect(!analytics.isEnabled, "only Continue applies the answer")
        #expect(!consent.hasAnswered)
    }

    @Test func continueRecordsAndAppliesTheAnswerBeforeCountingIt() {
        let model = makeModel()
        model.sharesAnalytics = true
        model.finish()
        #expect(consent.hasAnswered)
        #expect(consent.sharesAnalytics)
        #expect(!consent.sharesCrashReports)
        #expect(analytics.isEnabled)
        #expect(!crashes.isEnabled)
        #expect(analytics.events == [.onboardingCompleted(analytics: true, crash: false)])
    }
}
