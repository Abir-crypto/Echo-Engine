import EchoCore
import EchoCoreFakes
import Foundation
import Synchronization
import Testing

private final class ErrorLog: Sendable {
    let errors = Mutex<[ProjectRepositoryError]>([])

    func record(_ error: any Error) {
        errors.withLock { $0.append(error as? ProjectRepositoryError ?? .notFound) }
    }
}

struct ProjectAutosaverTests {
    private let clock = ManualClock()
    private let dates = FakeClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    private let errors = ErrorLog()

    private func project(_ title: String) -> Project {
        var project = Project(
            id: UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")!,
            title: title, mediaType: .audio, origin: .recorded, sourceFileName: "source.caf",
            sourceInfo: SourceInfo(
                duration: 30, container: "com.apple.coreaudio-format", audioCodec: "lpcm", videoCodec: nil,
                byteSize: 1_000, channelCount: 1, sampleRate: 48_000
            ),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        project.updatedAt = project.createdAt
        return project
    }

    private func makeAutosaver(_ repository: FakeProjectRepository) -> ProjectAutosaver {
        ProjectAutosaver(repository: repository, clock: clock, dateProvider: dates, onError: errors.record)
    }

    /// Lets the autosaver's timer task run until it is suspended in `sleep`.
    private func waitForTimer() async throws {
        for _ in 0..<10_000 where clock.sleeperCount == 0 {
            await Task.yield()
        }
        try #require(clock.sleeperCount == 1)
    }

    /// Lets tasks woken by the clock run until `condition` holds.
    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    @Test func changeIsSavedOnlyAfterTheDelay() async throws {
        let repository = FakeProjectRepository()
        let autosaver = makeAutosaver(repository)

        await autosaver.schedule(project("Take 1"))
        try await waitForTimer()
        clock.advance(by: .milliseconds(999))
        for _ in 0..<100 { await Task.yield() }
        #expect(await repository.saveCount == 0)

        clock.advance(by: .milliseconds(1))
        #expect(await eventually { await repository.saveCount == 1 })
        #expect(await repository.list().map(\.project.title) == ["Take 1"])
    }

    @Test func eachChangeRestartsTheDelayAndTheLatestWins() async throws {
        let repository = FakeProjectRepository()
        let autosaver = makeAutosaver(repository)

        await autosaver.schedule(project("Take 1"))
        try await waitForTimer()
        clock.advance(by: .milliseconds(600))
        await autosaver.schedule(project("Take 2"))
        #expect(await eventually { clock.sleeperCount == 1 })
        try await waitForTimer()

        clock.advance(by: .milliseconds(600))
        for _ in 0..<100 { await Task.yield() }
        #expect(await repository.saveCount == 0)

        clock.advance(by: .milliseconds(400))
        #expect(await eventually { await repository.saveCount == 1 })
        #expect(await repository.list().map(\.project.title) == ["Take 2"])
    }

    @Test func flushSavesImmediatelyAndCancelsTheTimer() async throws {
        let repository = FakeProjectRepository()
        let autosaver = makeAutosaver(repository)

        await autosaver.schedule(project("Take 1"))
        await autosaver.flush()
        #expect(await repository.saveCount == 1)

        #expect(await eventually { clock.sleeperCount == 0 })
        clock.advance(by: .seconds(5))
        for _ in 0..<100 { await Task.yield() }
        #expect(await repository.saveCount == 1)
    }

    @Test func flushWithoutChangesSavesNothing() async {
        let repository = FakeProjectRepository()
        await makeAutosaver(repository).flush()
        #expect(await repository.saveCount == 0)
    }

    @Test func savedProjectIsStampedWithTheChangeTime() async throws {
        let repository = FakeProjectRepository()
        let autosaver = makeAutosaver(repository)

        await autosaver.schedule(project("Take 1"))
        await autosaver.flush()

        #expect(try await repository.load(id: project("Take 1").id).project.updatedAt == dates.now)
    }

    @Test func saveFailuresAreReported() async {
        let readOnly = project("From a newer app")
        let repository = FakeProjectRepository(projects: [readOnly], readOnlyIDs: [readOnly.id])
        let autosaver = makeAutosaver(repository)

        await autosaver.schedule(readOnly)
        await autosaver.flush()

        #expect(errors.errors.withLock { $0 } == [.readOnly])
    }
}
