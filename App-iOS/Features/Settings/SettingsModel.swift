import EchoCore
import Foundation
import Observation

/// Settings (SPEC § 14.2): appearance, tint, privacy consent, storage sizes and Clear cache, version.
@MainActor
@Observable
final class SettingsModel {
    let settings: any AppSettingsStore
    let consent: any ConsentStore
    /// "1.0 (1)": marketing version and build.
    let version: String
    /// Every project's folder on disk; nil until measured.
    private(set) var projectsBytes: Int64?
    /// Renders and waveform caches; nil until measured.
    private(set) var cacheBytes: Int64?
    private(set) var isClearing = false

    @ObservationIgnored private let projects: any ProjectRepository
    @ObservationIgnored private let renders: any RenderCaching
    @ObservationIgnored private let waveforms: any WaveformProviding

    init(
        settings: any AppSettingsStore, consent: any ConsentStore, projects: any ProjectRepository, renders: any RenderCaching,
        waveforms: any WaveformProviding, version: String
    ) {
        self.settings = settings
        self.consent = consent
        self.projects = projects
        self.renders = renders
        self.waveforms = waveforms
        self.version = version
    }

    func load() async {
        var total: Int64 = 0
        for stored in (try? await projects.list()) ?? [] {
            total += (try? await projects.diskUsage(id: stored.project.id)) ?? 0
        }
        projectsBytes = total
        await measureCache()
    }

    /// Deletes every render and cached waveform; projects make them again when they open (SPEC § 6.4, § 14.2).
    func clearCache() async {
        isClearing = true
        defer { isClearing = false }
        try? await renders.removeEverything()
        try? await waveforms.removeEverything()
        await measureCache()
    }

    private func measureCache() async {
        let renderBytes = (try? await renders.totalBytes()) ?? 0
        let waveformBytes = (try? await waveforms.totalBytes()) ?? 0
        cacheBytes = renderBytes + waveformBytes
    }
}
