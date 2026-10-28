#if DEBUG
import EchoCore
import EchoCoreFakes
import SwiftUI

/// Temporary debug tools until the Settings screen exists (F13.T01): appearance, tint and sample projects.
/// Debug builds only, so its labels are verbatim and stay out of the String Catalog.
struct DebugMenu: View {
    @Environment(AppContainer.self) private var container
    @AppStorage(AppSettingsKey.appearance) private var appearance = Appearance.default
    @AppStorage(AppSettingsKey.tint) private var tint = AppTint.default

    var body: some View {
        Menu {
            Picker(selection: $appearance) {
                ForEach(Appearance.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
            } label: {
                Text(verbatim: "Appearance")
            }
            Picker(selection: $tint) {
                ForEach(AppTint.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
            } label: {
                Text(verbatim: "Tint")
            }
            Button {
                Task { await DebugSampleProjects.add(to: container.projects) }
            } label: {
                Text(verbatim: "Add sample projects")
            }
        } label: {
            Image(systemName: "ladybug")
                .accessibilityLabel(Text(verbatim: "Debug menu"))
        }
    }
}

/// The Home mockup's projects, saved as real (media-less) projects for manual testing.
enum DebugSampleProjects {
    /// `-seedSampleProjects YES` adds them at launch.
    static let launchArgument = "seedSampleProjects"

    static func add(to repository: any ProjectRepository) async {
        for project in PreviewProjects.all() {
            try? await repository.save(project)
        }
    }
}
#endif
