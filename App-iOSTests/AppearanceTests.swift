@testable import EchoEngine
import SwiftUI
import Testing

struct AppearanceTests {
    @Test func systemFollowsDeviceSetting() {
        #expect(Appearance.system.colorScheme == nil)
    }

    @Test func explicitAppearancesForceScheme() {
        #expect(Appearance.dark.colorScheme == .dark)
        #expect(Appearance.light.colorScheme == .light)
    }

    @Test func defaultsMatchSpec() {
        #expect(Appearance.default == .system)
        #expect(AppTint.default == .amber)
    }
}
