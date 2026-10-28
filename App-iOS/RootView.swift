import SwiftUI
#if DEBUG
import EchoCoreFakes
#endif

enum AppTab: Hashable {
    case projects, record
}

/// Tab shell (SPEC § 14.1). Appearance and tint are applied by `EchoEngineApp`.
struct RootView: View {
    let container: AppContainer
    let homeModel: HomeModel
    let importModel: ImportModel
    @State private var selectedTab = AppTab.projects

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Projects", systemImage: "square.grid.2x2", value: AppTab.projects) {
                HomeView(model: homeModel, importModel: importModel, onRecord: { selectedTab = .record })
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
            if let path = UserDefaults.standard.string(forKey: DebugImport.launchArgument) {
                importModel.importFile(at: URL(filePath: path))
            }
        }
        #endif
    }
}

#if DEBUG
@MainActor
private func previewRoot() -> RootView {
    let container = AppContainer(projects: FakeProjectRepository(projects: PreviewProjects.all()))
    return RootView(container: container, homeModel: container.makeHomeModel(), importModel: container.makeImportModel())
}

#Preview("Dark") {
    previewRoot()
        .tint(AppTint.default.text)
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    previewRoot()
        .tint(AppTint.default.text)
        .preferredColorScheme(.light)
}

#Preview("Arabic RTL, XXL") {
    previewRoot()
        .tint(AppTint.default.text)
        .environment(\.locale, Locale(identifier: "ar"))
        .environment(\.layoutDirection, .rightToLeft)
        .dynamicTypeSize(.xxxLarge)
}
#endif
