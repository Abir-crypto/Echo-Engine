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

/// `-debugAutoplay YES` starts playback when the editor opens.
enum DebugAutoplay {
    static let launchArgument = "debugAutoplay"
}

/// `-debugAdjustSheet equalizer|gainDynamics|effects` opens that Adjust sheet when the editor opens.
enum DebugAdjustSheet {
    static let launchArgument = "debugAdjustSheet"
}

/// `-debugManualDemo YES` turns on a sample of every Adjust control when the editor opens (not saved).
enum DebugManualDemo {
    static let launchArgument = "debugManualDemo"

    static func apply(_ manual: inout ManualSettings) {
        manual.inputGainDB = 2.5
        manual.eq[0].gainDB = 3
        manual.eq[2].gainDB = -4
        manual.eq[4].gainDB = 5
        manual.gate.isEnabled = true
        manual.compressor.isEnabled = true
        manual.compressor.makeupDB = 2
        manual.deEsser.isEnabled = true
        manual.pitchSemitones = 2
        manual.reverb.isEnabled = true
    }
}

/// `-debugAIDemo YES` adds Noise Suppression to the opened project (an undoable change), until the Enhance UI exists.
enum DebugAIDemo {
    static let launchArgument = "debugAIDemo"
}

/// `-debugImportPath <file>` imports that file at launch, as if chosen in Files.
enum DebugImport {
    static let launchArgument = "debugImportPath"
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
