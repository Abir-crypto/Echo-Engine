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

@MainActor
struct ProjectInfoTests {
    @Test func theInfoSheetMeasuresTheProject() async {
        let project = PreviewProjects.all()[0]
        let repository = FakeProjectRepository(projects: [project])
        await repository.setStorage(ProjectStorage(source: 900, working: 300, takes: 0, folder: 1_250), for: project.id)
        let model = HomeModel(repository: repository, storage: FakeStorageEstimator(), waveforms: FakeWaveformProvider(), renders: FakeRenderCache())
        let storage = await model.storage(of: project.id)
        #expect(storage?.folder == ProjectStorage(source: 900, working: 300, takes: 0, folder: 1_250))
        #expect(storage?.renders == 0)
        #expect(await model.storage(of: UUID()) == nil, "a missing project can't be measured")
    }
}
