#if DEBUG
import EchoCore
import EchoCoreFakes
import SwiftUI

/// Temporary debug tools until the Settings screen exists (F13.T01): appearance, tint and sample projects.
/// Debug builds only, so its labels are verbatim and stay out of the String Catalog.
struct DebugMenu: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        Menu {
            Picker(selection: Binding(get: { container.settings.appearance }, set: { container.settings.appearance = $0 })) {
                ForEach(Appearance.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
            } label: {
                Text(verbatim: "Appearance")
            }
            Picker(selection: Binding(get: { container.settings.tint }, set: { container.settings.tint = $0 })) {
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

/// `-debugExportSheet YES` opens the export sheet when the editor opens.
enum DebugExportSheet {
    static let launchArgument = "debugExportSheet"
}

/// `-debugAdjustSheet equalizer|gainDynamics|effects|loudness` opens that Adjust sheet when the editor opens.
enum DebugAdjustSheet {
    static let launchArgument = "debugAdjustSheet"
}

/// `-debugLoudness youtube|instagram|tiktok|spotify|podcast|appleMusic|custom<LUFS>` (e.g. `custom-23.5`) sets the
/// Auto Level target when the editor opens, like choosing it on the Loudness screen.
enum DebugLoudness {
    static let launchArgument = "debugLoudness"

    static func target(_ value: String) -> LoudnessTarget? {
        if value.hasPrefix("custom") {
            return .custom(lufs: Double(value.dropFirst("custom".count)) ?? LoudnessTarget.customDefault)
        }
        return LoudnessTarget.platformTargets.first { String(describing: $0) == value }
    }
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

/// `-debugAIDemo YES` adds Noise Suppression and Clear Voice to the opened project (undoable changes).
enum DebugAIDemo {
    static let launchArgument = "debugAIDemo"
}

/// `-debugEnhanceSheet add|strength|presets` opens Add enhancement, the first step's strength or Apply preset when the
/// editor opens.
enum DebugEnhanceSheet {
    static let launchArgument = "debugEnhanceSheet"
}

/// `-debugImportPath <file>` imports that file at launch, as if chosen in Files.
enum DebugImport {
    static let launchArgument = "debugImportPath"
}

/// `-debugLiveActivity YES` shows the recording Live Activity with a moving level and no recording, to check its
/// layout (leave the app for the Dynamic Island, lock the device for the Lock Screen). Its Stop ends it.
enum DebugLiveActivity {
    static let launchArgument = "debugLiveActivity"

    @MainActor
    static func run(_ container: AppContainer) {
        let activity = container.recordingActivity
        activity.start(tint: container.settings.tint)
        let demo = Task { @MainActor in
            let start = ContinuousClock.now
            var step = 0.0
            while !Task.isCancelled {
                let elapsed = start.duration(to: .now) / .seconds(1)
                activity.update(elapsedSeconds: elapsed, isPaused: false, level: 0.5 + 0.45 * sin(step))
                step += 0.7
                try? await Task.sleep(for: .milliseconds(500))
            }
            activity.end()
        }
        container.recordingStopRelay.handler = { demo.cancel() }
    }
}

/// `-debugUnfinishedTake YES` leaves a 3-second take as a killed app would (files open, session marker, no manifest),
/// so the launch offers to recover it.
enum DebugUnfinishedTake {
    static let launchArgument = "debugUnfinishedTake"

    static func create(in projects: any ProjectRepository) async {
        guard let folder = try? await projects.createFolder(for: UUID()) else { return }
        let takes = folder.takeFolder
        try? FileManager().createDirectory(at: takes.url, withIntermediateDirectories: true)
        let samples = (0..<144_000).map { 0.3 * sin(2 * Float.pi * 220 * Float($0) / 48_000) * (1 + sin(Float($0) / 9_000)) / 2 }
        samples.withUnsafeBufferPointer { pointer in
            for url in [takes.raw, takes.processed] {
                // Never closed, like a take the app was killed during.
                let writer = try? CAFWriter(url: url, sampleRate: 48_000, channelCount: 1)
                try? writer?.append([pointer.baseAddress!], frames: samples.count)
            }
        }
        try? TakeSession(startedAt: Date().addingTimeInterval(-3), channelNames: ["Host"]).write(to: takes)
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
