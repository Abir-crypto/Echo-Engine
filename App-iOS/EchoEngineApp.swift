import SwiftUI

@main
struct EchoEngineApp: App {
    @State private var container: AppContainer
    /// Screen models are created once here, not in `RootView.init`, which runs again whenever the appearance or
    /// tint changes.
    @State private var homeModel: HomeModel
    @State private var importModel: ImportModel
    @AppStorage(AppSettingsKey.appearance) private var appearance = Appearance.default
    @AppStorage(AppSettingsKey.tint) private var tint = AppTint.default

    init() {
        let container = AppContainer()
        _container = State(initialValue: container)
        _homeModel = State(initialValue: container.makeHomeModel())
        _importModel = State(initialValue: container.makeImportModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView(container: container, homeModel: homeModel, importModel: importModel)
                .environment(\.appTint, tint)
                // System-tinted controls are mostly text and icons on Ground, so they use the text role.
                .tint(tint.text)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}
