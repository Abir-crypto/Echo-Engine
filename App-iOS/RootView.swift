import SwiftUI
#if DEBUG
import EchoCoreFakes
#endif

enum AppTab: Hashable {
    case projects, record
}

/// Tab shell (SPEC § 14.1). Appearance and tint are applied by `EchoEngineApp`.
struct RootView: View {
    private let container: AppContainer
    @State private var selectedTab = AppTab.projects
    @State private var homeModel: HomeModel

    init(container: AppContainer) {
        self.container = container
        _homeModel = State(initialValue: container.makeHomeModel())
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Projects", systemImage: "square.grid.2x2", value: AppTab.projects) {
                HomeView(model: homeModel, onImport: {}, onRecord: { selectedTab = .record })
            }
            Tab("Record", systemImage: "mic", value: AppTab.record) {
                RecordView()
            }
        }
        .environment(container)
        #if DEBUG
        .task {
            if UserDefaults.standard.bool(forKey: DebugSampleProjects.launchArgument) {
                await DebugSampleProjects.add(to: container.projects)
                await homeModel.load()
            }
        }
        #endif
    }
}

#if DEBUG
@MainActor
private func previewContainer() -> AppContainer {
    AppContainer(projects: FakeProjectRepository(projects: PreviewProjects.all()))
}

#Preview("Dark") {
    RootView(container: previewContainer())
        .tint(AppTint.default.text)
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    RootView(container: previewContainer())
        .tint(AppTint.default.text)
        .preferredColorScheme(.light)
}

#Preview("Arabic RTL, XXL") {
    RootView(container: previewContainer())
        .tint(AppTint.default.text)
        .environment(\.locale, Locale(identifier: "ar"))
        .environment(\.layoutDirection, .rightToLeft)
        .dynamicTypeSize(.xxxLarge)
}
#endif
