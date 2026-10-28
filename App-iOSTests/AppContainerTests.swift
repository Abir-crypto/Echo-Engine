import EchoCore
import EchoCoreFakes
@testable import EchoEngine
import Testing

@MainActor
struct AppContainerTests {
    @Test func defaultsToV1Services() {
        let container = AppContainer()
        #expect(container.entitlements is FreeV1Entitlements)
        #expect(container.capabilities is DefaultCapabilities)
    }

    @Test func usesInjectedServices() {
        let container = AppContainer(
            entitlements: FakeEntitlements(locked: [.clearVoice]),
            capabilities: FakeCapabilities(unsupported: [.exportVideo])
        )
        #expect(!container.entitlements.isUnlocked(.clearVoice))
        #expect(!container.capabilities.supports(.exportVideo))
    }
}
