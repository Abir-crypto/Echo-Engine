import EchoCore
import EchoCoreFakes
import Testing

struct EntitlementsTests {
    @Test(arguments: GatedFeature.allCases)
    func freeV1UnlocksEverything(_ feature: GatedFeature) {
        #expect(FreeV1Entitlements().isUnlocked(feature))
    }

    @Test(arguments: GatedFeature.allCases)
    func defaultCapabilitiesSupportEverything(_ feature: GatedFeature) {
        #expect(DefaultCapabilities().supports(feature))
    }

    @Test func fakesLockOnlyListedFeatures() {
        let entitlements = FakeEntitlements(locked: [.clearVoice])
        let capabilities = FakeCapabilities(unsupported: [.exportVideo])
        #expect(!entitlements.isUnlocked(.clearVoice))
        #expect(entitlements.isUnlocked(.noiseSuppression))
        #expect(!capabilities.supports(.exportVideo))
        #expect(capabilities.supports(.exportAudio))
    }
}
