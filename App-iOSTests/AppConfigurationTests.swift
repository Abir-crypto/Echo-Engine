import Foundation
import Testing

struct AppConfigurationTests {
    @Test func bundleIdentifierMatchesSpec() {
        #expect(Bundle.main.bundleIdentifier == "akumatech.Echo-Engine")
    }

    @Test func displayNameMatchesSpec() {
        let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        #expect(displayName == "Echo Engine")
    }

    @Test(arguments: ["NSMicrophoneUsageDescription", "NSPhotoLibraryAddUsageDescription"])
    func usageDescriptionIsPresent(_ key: String) {
        let text = Bundle.main.object(forInfoDictionaryKey: key) as? String
        #expect(text?.isEmpty == false)
    }

    @Test func exportsMayContinueInTheBackground() {
        let identifiers = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        #expect(identifiers == ["akumatech.Echo-Engine.export.*"])
    }

    @Test func backgroundAudioIsEnabled() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        #expect(modes == ["audio"])
    }

    /// SPEC § 16: no tracking; every required-reason API the app calls is declared.
    @Test func privacyManifestDeclaresNoTrackingAndItsAPIs() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: 0, format: nil) as? [String: Any])
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        let apis = (manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []).compactMap { $0["NSPrivacyAccessedAPIType"] as? String }
        #expect(Set(apis) == [
            "NSPrivacyAccessedAPICategoryUserDefaults", "NSPrivacyAccessedAPICategoryDiskSpace", "NSPrivacyAccessedAPICategorySystemBootTime",
        ])
        let collected = (manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? [])
        #expect(collected.allSatisfy { $0["NSPrivacyCollectedDataTypeTracking"] as? Bool == false })
    }

    /// SPEC § 16: no IDFA, and collection off until consent.
    @Test func firebaseStartsWithCollectionOff() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["FIREBASE_ANALYTICS_COLLECTION_ENABLED"] as? Bool == false)
        #expect(info["FirebaseCrashlyticsCollectionEnabled"] as? Bool == false)
        #expect(info["GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS"] as? Bool == false)
        #expect(info["GOOGLE_ANALYTICS_ADID_COLLECTION_ENABLED"] as? Bool == false)
    }
}
