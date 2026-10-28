import EchoCore
import Observation

/// Composition root: the only place that names concrete service types (SPEC § 4.4).
/// Injected into SwiftUI with `.environment(_:)`; tests and previews pass fakes to `init`.
@MainActor
@Observable
final class AppContainer {
    let entitlements: any EntitlementProvider
    let capabilities: any DeviceCapabilityChecking

    init(
        entitlements: any EntitlementProvider = FreeV1Entitlements(),
        capabilities: any DeviceCapabilityChecking = DefaultCapabilities()
    ) {
        self.entitlements = entitlements
        self.capabilities = capabilities
    }
}
