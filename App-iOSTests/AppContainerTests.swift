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
        #expect(container.projects is FileProjectRepository)
    }

    @Test func everyOfferedEnhancementHasAProcessor() {
        #expect(Set(EditorModel.offeredFeatures).isSubset(of: AppContainer.aiProcessors.keys))
        #expect(AppContainer.aiProcessors[.voiceLeveler] is VoiceLevelerProcessor)
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
