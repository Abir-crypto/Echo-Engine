import SwiftUI

@main
struct EchoEngineApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            Text("Echo Engine")
                .environment(container)
        }
    }
}
