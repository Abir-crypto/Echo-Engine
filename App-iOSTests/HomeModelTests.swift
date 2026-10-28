import EchoCore
import EchoCoreFakes
@testable import EchoEngine
import Foundation
import Testing
import UIKit

@MainActor
struct HomeModelTests {
    private let samples = PreviewProjects.all(now: Date(timeIntervalSince1970: 1_800_000_000))

    private func makeModel(_ repository: FakeProjectRepository, storage: FakeStorageEstimator = FakeStorageEstimator()) -> HomeModel {
        HomeModel(repository: repository, storage: storage)
    }

    @Test func loadsProjectsMostRecentFirst() async {
        let model = makeModel(FakeProjectRepository(projects: samples.shuffled()))
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.projects.map(\.project.title) == samples.map(\.title))
    }

    @Test func emptyRepositoryIsLoadedAndEmpty() async {
        let model = makeModel(FakeProjectRepository())
        #expect(!model.hasLoaded)
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.projects.isEmpty)
    }

    @Test func renameTrimsWhitespaceAndReloads() async throws {
        let renameTime = FakeClock(now: Date(timeIntervalSince1970: 1_800_100_000))
        let repository = FakeProjectRepository(projects: samples, clock: renameTime)
        let model = makeModel(repository)
        await model.load()

        await model.rename(samples[2].id, to: "  Interview, final  ")

        #expect(try await repository.load(id: samples[2].id).project.title == "Interview, final")
        #expect(model.projects.first?.project.title == "Interview, final")
    }

    @Test func blankTitleIsIgnored() async throws {
        let repository = FakeProjectRepository(projects: samples)
        let model = makeModel(repository)

        await model.rename(samples[0].id, to: "   ")

        #expect(await repository.saveCount == 0)
        #expect(model.failure == nil)
    }

    @Test func renamingAProjectFromANewerAppReportsReadOnly() async {
        let model = makeModel(FakeProjectRepository(projects: samples, readOnlyIDs: [samples[0].id]))
        await model.rename(samples[0].id, to: "New title")
        #expect(model.failure == .readOnly)
    }

    @Test func deleteRemovesTheProject() async throws {
        let repository = FakeProjectRepository(projects: samples)
        let model = makeModel(repository)
        await model.load()

        await model.delete(samples[1].id)

        #expect(!model.projects.contains { $0.project.id == samples[1].id })
        #expect(await repository.list().count == samples.count - 1)
    }

    @Test func deletingAMissingProjectReportsFailure() async {
        let model = makeModel(FakeProjectRepository())
        await model.delete(UUID())
        #expect(model.failure == .delete)
    }

    @Test func diskUsageComesFromTheRepository() async {
        let model = makeModel(FakeProjectRepository(projects: samples, diskUsageByID: [samples[0].id: 1_400_000_000]))
        #expect(await model.diskUsage(of: samples[0].id) == 1_400_000_000)
        #expect(await model.diskUsage(of: UUID()) == nil)
    }

    @Test func readinessComesFromFreeSpace() async {
        let model = makeModel(
            FakeProjectRepository(projects: samples),
            storage: FakeStorageEstimator(editBytes: 1_200_000_000, exportBytes: 900_000_000, available: 1_000_000_000)
        )
        await model.load()
        #expect(model.readiness[samples[0].id] == .needsSpaceToEdit(200_000_000))
        #expect(model.readiness.count == samples.count)
    }

    @Test func videoShowsItsFrameAndAudioItsOverview() async throws {
        let video = samples[0], audio = samples[1]
        let jpeg = try #require(UIImage(systemName: "video")?.jpegData(compressionQuality: 0.8))
        let model = makeModel(FakeProjectRepository(
            projects: samples, overviewsByID: [audio.id: [0.2, 0.4]], thumbnailsByID: [video.id: jpeg]
        ))

        await model.loadThumbnail(for: video)
        await model.loadThumbnail(for: audio)
        await model.loadThumbnail(for: samples[2])

        guard case .frame = model.thumbnails[video.id] else { Issue.record("expected a frame"); return }
        guard case .levels(let levels) = model.thumbnails[audio.id] else { Issue.record("expected levels"); return }
        #expect(levels == [0.2, 0.4])
        #expect(model.thumbnails[samples[2].id] == nil)
    }
}

struct WaveformBarsTests {
    @Test func downsamplesByPeakAndScalesToTheLoudest() {
        let levels: [Float] = [0.1, 0.5, 0.2, 0.25, 0, 0]
        let bars = WaveformBars.bars(from: levels, count: 3)
        #expect(bars.count == 3)
        #expect(bars[0] == 1)
        #expect(abs(bars[1] - (WaveformBars.floor + (1 - WaveformBars.floor) * 0.5)) < 1e-9)
        #expect(bars[2] == WaveformBars.floor)
    }

    @Test func fewerLevelsThanBarsStillFillEveryBar() {
        #expect(WaveformBars.bars(from: [0.5, 1], count: 24).count == 24)
    }

    @Test func silenceIsAFlatLowLine() {
        #expect(WaveformBars.bars(from: [0, 0, 0], count: 3) == [WaveformBars.floor, WaveformBars.floor, WaveformBars.floor])
    }
}
