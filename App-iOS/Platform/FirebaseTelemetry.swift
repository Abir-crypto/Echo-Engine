import EchoCore
import FirebaseAnalytics
import FirebaseCore
import FirebaseCrashlytics
import Foundation

/// The only code that talks to Firebase (SPEC § 16). Collection starts off (Info.plist) and follows consent through
/// `TelemetryConsent`.
enum FirebaseSetup {
    /// Configures Firebase when the app carries `GoogleService-Info.plist`; without it the no-op trackers run.
    static func configureIfAvailable() -> Bool {
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else { return false }
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        return true
    }
}

@MainActor
final class FirebaseAnalyticsTracker: AnalyticsTracking {
    private var isEnabled = false

    func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        // Analytics storage per consent; nothing for advertising, ever.
        Analytics.setConsent([
            .analyticsStorage: isEnabled ? .granted : .denied,
            .adStorage: .denied, .adUserData: .denied, .adPersonalization: .denied,
        ])
        Analytics.setAnalyticsCollectionEnabled(isEnabled)
    }

    func track(_ event: AnalyticsEvent) {
        guard isEnabled else { return }
        Analytics.logEvent(event.name, parameters: event.parameters.mapValues(\.firebaseValue))
    }
}

@MainActor
final class CrashlyticsReporter: CrashReporting {
    private let crashlytics = Crashlytics.crashlytics()

    func setEnabled(_ isEnabled: Bool) {
        crashlytics.setCrashlyticsCollectionEnabled(isEnabled)
        // Reports kept from a time without consent are never sent later.
        if !isEnabled { crashlytics.deleteUnsentReports() }
    }

    func setContext(_ key: CrashContextKey, _ value: String) {
        crashlytics.setCustomValue(value, forKey: key.rawValue)
    }

    func log(_ message: StaticString) {
        crashlytics.log("\(message)")
    }

    func record(_ error: any Error) {
        // Domain and code only: user info can carry file paths and names.
        let error = error as NSError
        crashlytics.record(error: NSError(domain: error.domain, code: error.code))
    }
}

private extension AnalyticsValue {
    /// Firebase takes strings and numbers; flags go as 0/1.
    var firebaseValue: Any {
        switch self {
        case let .string(value): value
        case let .int(value): value
        case let .bool(value): value ? 1 : 0
        }
    }
}
