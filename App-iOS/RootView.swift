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
    let recordModel: RecordModel
    @State private var selectedTab = AppTab.projects
    /// A recorded or recovered project to open in the Editor.
    @State private var projectToOpen: UUID?

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Projects", systemImage: "square.grid.2x2", value: AppTab.projects) {
                HomeView(
                    model: homeModel, importModel: importModel, onRecord: { selectedTab = .record },
                    openProjectID: projectToOpen, onOpenedProject: { projectToOpen = nil }
                )
            }
            Tab("Record", systemImage: "mic", value: AppTab.record) {
                RecordView(model: recordModel)
            }
        }
        .environment(container)
        // Takes the app was killed during (SPEC § 13.3).
        .recordingRecoveryAlerts(recoveryModel)
        .onChange(of: recoveryModel.recoveredProjectID) { _, id in
            guard let id else { return }
            open(id)
            recoveryModel.didOpenRecoveredProject()
        }
        // Stop opens the new recording in the Editor (SPEC § 13.3).
        .onChange(of: recordModel.finishedProjectID) { _, id in
            guard let id else { return }
            open(id)
            recordModel.didOpenFinishedProject()
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
            if UserDefaults.standard.string(forKey: DebugRecordTab.tabArgument) == "record" {
                selectedTab = .record
                for _ in 0..<50 where !recordModel.canRecord {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if DebugRecordTab.usesFakes { DebugRecordTab.stageMockup(recordModel) }
                if UserDefaults.standard.bool(forKey: DebugRecordTab.recordArgument) {
                    await recordModel.record()
                    (recordModel.engine as? FakeRecordingEngine)?.elapsedSeconds = 767
                    if UserDefaults.standard.string(forKey: DebugRecordTab.sheetArgument) == "dim" { recordModel.isDimmed = true }
                }
            }
        }
        #endif
    }

    private func open(_ id: UUID) {
        selectedTab = .projects
        projectToOpen = id
    }
}

#if DEBUG
@MainActor
private func previewRoot() -> RootView {
    let container = AppContainer(projects: FakeProjectRepository(projects: PreviewProjects.all()))
    return RootView(
        container: container, homeModel: container.makeHomeModel(), importModel: container.makeImportModel(),
        recoveryModel: container.makeRecordingRecoveryModel(), recordModel: previewRecordModel()
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
