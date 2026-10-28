import SwiftUI

@main
struct EchoEngineApp: App {
    @State private var container: AppContainer
    /// Created once here, not in `RootView.init`, which runs again whenever the appearance or tint changes.
    @State private var homeModel: HomeModel
    @AppStorage(AppSettingsKey.appearance) private var appearance = Appearance.default
    @AppStorage(AppSettingsKey.tint) private var tint = AppTint.default

    init() {
        let container = AppContainer()
        _container = State(initialValue: container)
        _homeModel = State(initialValue: container.makeHomeModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView(container: container, homeModel: homeModel)
                .environment(\.appTint, tint)
                // System-tinted controls are mostly text and icons on Ground, so they use the text role.
                .tint(tint.text)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}
