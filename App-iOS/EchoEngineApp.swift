import SwiftUI

@main
struct EchoEngineApp: App {
    @State private var container = AppContainer()
    @AppStorage(AppSettingsKey.appearance) private var appearance = Appearance.default
    @AppStorage(AppSettingsKey.tint) private var tint = AppTint.default

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
                .environment(\.appTint, tint)
                // System-tinted controls are mostly text and icons on Ground, so they use the text role.
                .tint(tint.text)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}
