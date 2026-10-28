import EchoCore
import EchoCoreFakes
@testable import EchoEngine
import Foundation
import Testing

@MainActor
struct HomeModelTests {
    private let samples = PreviewProjects.all(now: Date(timeIntervalSince1970: 1_800_000_000))

    @Test func loadsProjectsMostRecentFirst() async {
        let model = HomeModel(repository: FakeProjectRepository(projects: samples.shuffled()))
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.projects.map(\.project.title) == samples.map(\.title))
    }

    @Test func emptyRepositoryIsLoadedAndEmpty() async {
        let model = HomeModel(repository: FakeProjectRepository())
        #expect(!model.hasLoaded)
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.projects.isEmpty)
    }

    @Test func renameTrimsWhitespaceAndReloads() async throws {
        let renameTime = FakeClock(now: Date(timeIntervalSince1970: 1_800_100_000))
        let repository = FakeProjectRepository(projects: samples, clock: renameTime)
        let model = HomeModel(repository: repository)
        await model.load()

        await model.rename(samples[2].id, to: "  Interview, final  ")

        #expect(try await repository.load(id: samples[2].id).project.title == "Interview, final")
        #expect(model.projects.first?.project.title == "Interview, final")
    }

    @Test func blankTitleIsIgnored() async throws {
        let repository = FakeProjectRepository(projects: samples)
        let model = HomeModel(repository: repository)

        await model.rename(samples[0].id, to: "   ")

        #expect(await repository.saveCount == 0)
        #expect(model.failure == nil)
    }

    @Test func renamingAProjectFromANewerAppReportsReadOnly() async {
        let model = HomeModel(repository: FakeProjectRepository(projects: samples, readOnlyIDs: [samples[0].id]))
        await model.rename(samples[0].id, to: "New title")
        #expect(model.failure == .readOnly)
    }

    @Test func deleteRemovesTheProject() async throws {
        let repository = FakeProjectRepository(projects: samples)
        let model = HomeModel(repository: repository)
        await model.load()

        await model.delete(samples[1].id)

        #expect(!model.projects.contains { $0.project.id == samples[1].id })
        #expect(await repository.list().count == samples.count - 1)
    }

    @Test func deletingAMissingProjectReportsFailure() async {
        let model = HomeModel(repository: FakeProjectRepository())
        await model.delete(UUID())
        #expect(model.failure == .delete)
    }

    @Test func diskUsageComesFromTheRepository() async {
        let model = HomeModel(repository: FakeProjectRepository(projects: samples, diskUsageByID: [samples[0].id: 1_400_000_000]))
        #expect(await model.diskUsage(of: samples[0].id) == 1_400_000_000)
        #expect(await model.diskUsage(of: UUID()) == nil)
    }
}
