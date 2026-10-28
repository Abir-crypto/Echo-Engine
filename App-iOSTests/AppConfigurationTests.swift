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
}
