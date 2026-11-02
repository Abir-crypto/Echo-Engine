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
        #expect(container.settings is UserDefaultsSettingsStore)
    }

    @Test func everyOfferedEnhancementHasAProcessor() {
        #expect(Set(EditorModel.offeredFeatures).isSubset(of: AppContainer.aiProcessors.keys))
        #expect(AppContainer.aiProcessors[.voiceLeveler] is VoiceLevelerProcessor)
    }

    @Test func everyExportDestinationIsThere() {
        let container = AppContainer()
        for kind in DestinationKind.allCases {
            #expect(container.destinations[kind]?.kind == kind)
        }
        #expect(container.destinations[.photos] is PhotosDestination)
        #expect(container.exportWorkspace.root == .exportTemporaryDirectory)
    }

    @Test func usesInjectedServices() {
        let container = AppContainer(
            entitlements: FakeEntitlements(locked: [.clearVoice]),
            capabilities: FakeCapabilities(unsupported: [.exportVideo]),
            settings: FakeAppSettingsStore(appearance: .dark, tint: .violet)
        )
        #expect(container.settings.appearance == .dark)
        #expect(container.settings.tint == .violet)
        #expect(!container.entitlements.isUnlocked(.clearVoice))
        #expect(!container.capabilities.supports(.exportVideo))
    }
}
