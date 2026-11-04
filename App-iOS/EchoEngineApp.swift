import AppIntents
import EchoCore
import SwiftUI

@main
struct EchoEngineApp: App {
    @State private var container: AppContainer
    /// Screen models are created once here, not in `RootView.init`, which runs again whenever the appearance or
    /// tint changes.
    @State private var homeModel: HomeModel
    @State private var importModel: ImportModel

    init() {
        let container = AppContainer()
        // Temporary files of exports the app never finished (it was quit or killed).
        container.exportWorkspace.removeAll()
        // A recording Live Activity of a take the app didn't finish (it was killed).
        container.recordingActivity.end()
        // The Live Activity's Stop runs in this process and finds the recording through the relay.
        AppDependencyManager.shared.add(dependency: container.recordingStopRelay)
        _container = State(initialValue: container)
        _homeModel = State(initialValue: container.makeHomeModel())
        _importModel = State(initialValue: container.makeImportModel())
    }

    var body: some Scene {
        WindowGroup {
            let tint = container.settings.tint
            RootView(container: container, homeModel: homeModel, importModel: importModel)
                .environment(\.appTint, tint)
                .environment(\.deviceFamily, .current)
                // System-tinted controls are mostly text and icons on Ground, so they use the text role.
                .tint(tint.text)
                .preferredColorScheme(container.settings.appearance.colorScheme)
        }
    }
}
