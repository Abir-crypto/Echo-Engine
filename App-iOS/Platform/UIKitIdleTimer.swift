import EchoCore
import UIKit

/// Wraps the app's idle timer (SPEC § 4.1: Apple singletons stay behind protocols).
@MainActor
final class UIKitIdleTimer: IdleTimerControlling {
    private let application: UIApplication

    init(application: UIApplication = .shared) {
        self.application = application
    }

    var keepsScreenOn: Bool {
        get { application.isIdleTimerDisabled }
        set { application.isIdleTimerDisabled = newValue }
    }
}
