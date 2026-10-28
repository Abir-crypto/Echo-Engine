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

    @Test func backgroundAudioIsEnabled() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        #expect(modes == ["audio"])
    }
}
