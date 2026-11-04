import EchoCore
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
    let recoveryModel: RecordingRecoveryModel
    @State private var selectedTab = AppTab.projects

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Projects", systemImage: "square.grid.2x2", value: AppTab.projects) {
                HomeView(model: homeModel, importModel: importModel, onRecord: { selectedTab = .record }, recovery: recoveryModel)
            }
            Tab("Record", systemImage: "mic", value: AppTab.record) {
                RecordView()
            }
        }
        .environment(container)
        // Takes the app was killed during (SPEC § 13.3).
        .recordingRecoveryAlerts(recoveryModel)
        .onChange(of: recoveryModel.recoveredProjectID) { _, id in
            if id != nil { selectedTab = .projects }
        }
        .task {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: DebugUnfinishedTake.launchArgument) {
                await DebugUnfinishedTake.create(in: container.projects)
            }
            #endif
            await recoveryModel.check()
        }
        #if DEBUG
        .task {
            if UserDefaults.standard.bool(forKey: DebugSampleProjects.launchArgument) {
                await DebugSampleProjects.add(to: container.projects)
                await homeModel.load()
            }
            if let path = UserDefaults.standard.string(forKey: DebugImport.launchArgument) {
                importModel.importFile(at: URL(filePath: path))
            }
            if UserDefaults.standard.bool(forKey: DebugLiveActivity.launchArgument) {
                DebugLiveActivity.run(container)
            }
        }
        #endif
    }
}

#if DEBUG
@MainActor
private func previewRoot() -> RootView {
    let container = AppContainer(projects: FakeProjectRepository(projects: PreviewProjects.all()))
    return RootView(
        container: container, homeModel: container.makeHomeModel(), importModel: container.makeImportModel(),
        recoveryModel: container.makeRecordingRecoveryModel()
    )
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
