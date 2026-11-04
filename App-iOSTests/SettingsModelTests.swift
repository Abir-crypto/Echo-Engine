import EchoCore
import EchoCoreFakes
@testable import EchoEngine
import Foundation
import Testing

@MainActor
struct SettingsModelTests {
    private let projects = PreviewProjects.all()

    @Test func storageAddsUpProjectsAndCaches() async {
        let repository = FakeProjectRepository(
            projects: Array(projects.prefix(2)), diskUsageByID: [projects[0].id: 3_000_000_000, projects[1].id: 1_900_000_000]
        )
        let renders = FakeRenderCache()
        await renders.setBytes(1_500_000_000)
        let waveforms = FakeWaveformProvider()
        await waveforms.setBytes(400_000_000)
        let model = SettingsModel(
            settings: FakeAppSettingsStore(), consent: FakeConsentStore(), projects: repository, renders: renders,
            waveforms: waveforms, version: "1.0 (1)"
        )
        #expect(model.projectsBytes == nil, "measured on load")
        await model.load()
        #expect(model.projectsBytes == 4_900_000_000)
        #expect(model.cacheBytes == 1_900_000_000, "renders and waveform caches together")

        await model.clearCache()
        #expect(await renders.removedEverythingCount == 1)
        #expect(await waveforms.removedEverythingCount == 1, "waveform caches go too (F13.T01a)")
        #expect(model.cacheBytes == 0)
    }

    @Test func choicesApplyAtOnce() {
        let settings = FakeAppSettingsStore()
        let consent = FakeConsentStore()
        let model = SettingsModel(
            settings: settings, consent: consent, projects: FakeProjectRepository(), renders: FakeRenderCache(),
            waveforms: FakeWaveformProvider(), version: "1.0 (1)"
        )
        model.settings.tint = .violet
        model.settings.appearance = .light
        model.consent.sharesAnalytics = true
        #expect(settings.tint == .violet)
        #expect(settings.appearance == .light)
        #expect(consent.sharesAnalytics)
        #expect(!consent.sharesCrashReports)
    }
}
