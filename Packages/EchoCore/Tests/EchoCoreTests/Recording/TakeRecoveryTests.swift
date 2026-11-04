import AVFoundation
import EchoCoreFakes
import Foundation
import Testing
@testable import EchoCore

struct TakeRecoveryTests {
    private let files = FileManager()
    private let started = Date(timeIntervalSince1970: 1_800_000_000)

    private func repository(_ root: URL) -> FileProjectRepository {
        FileProjectRepository(root: root, migrator: ProjectMigrator(), clock: FakeClock(now: started))
    }

    /// A take as a killed app leaves it: files with unknown sizes (`frames` frames, plus half a frame in `processed`)
    /// and the session marker, no manifest.
    @discardableResult
    private func killedTake(in repository: FileProjectRepository, frames: Int, startedAt: Date? = nil) async throws -> UUID {
        let id = UUID()
        let takes = try await repository.createFolder(for: id).takeFolder
        try files.createDirectory(at: takes.url, withIntermediateDirectories: true)
        let samples = (0..<frames).map { 0.5 * sin(Float($0) * 0.02) }
        try samples.withUnsafeBufferPointer { pointer in
            for url in [takes.raw, takes.processed] {
                let writer = try CAFWriter(url: url, sampleRate: 48_000, channelCount: 1)
                try writer.append([pointer.baseAddress!], frames: frames)
            }
        }
        let handle = try FileHandle(forWritingTo: takes.processed)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1, 2]))
        try handle.close()
        try TakeSession(
            startedAt: startedAt ?? started, channelNames: ["Host", "Guest 1"],
            markers: [RecordingMetadata.Marker(time: 0.25, kind: .interruption)]
        ).write(to: takes)
        return id
    }

    @Test func theSessionMarkerReadsBackAndToleratesMissingFields() throws {
        let folder = TakeFolder(url: try temporaryFolder())
        let session = TakeSession(startedAt: started, channelNames: ["Host"], markers: [.init(time: 3, kind: .routeChange)])
        try session.write(to: folder)
        #expect(try TakeSession.read(from: folder) == session)
        try Data(#"{"startedAt": 0}"#.utf8).write(to: folder.session)
        #expect(try TakeSession.read(from: folder) == TakeSession(startedAt: Date(timeIntervalSinceReferenceDate: 0), channelNames: []))
        try TakeSession.remove(from: folder)
        try TakeSession.remove(from: folder)
        #expect(!files.fileExists(atPath: folder.session.path()))
    }

    @Test func aFileLeftByAKilledAppIsFinishedWithoutItsHalfFrame() async throws {
        let repository = repository(try temporaryFolder())
        let id = try await killedTake(in: repository, frames: 4_800)
        let processed = repository.folder(for: id).takeFolder.processed
        #expect(try CAFWriter.frameCount(at: processed) == 4_800)
        #expect(try CAFWriter.finish(at: processed) == 4_800)
        #expect(try files.attributesOfItem(atPath: processed.path())[.size] as? Int == 68 + 4_800 * 4)
        #expect(try CAFWriter.finish(at: processed) == 4_800, "a finished file is left alone")
        #expect(try readSamples(processed).channels[0].count == 4_800)
    }

    @Test func aRecoveredTakeBecomesARecordedProject() async throws {
        let root = try temporaryFolder()
        let repository = repository(root)
        let id = try await killedTake(in: repository, frames: 24_000)
        let recovery = TakeRecovery(root: root, repository: repository, builder: RecordedProjectBuilder(repository: repository, inspector: AVMediaInspector()))

        let takes = await recovery.unfinishedTakes()
        #expect(takes.map(\.id) == [id])
        #expect(takes.first?.duration == 0.5)
        let project = try await recovery.recover(try #require(takes.first), title: "Recording, today")

        #expect(project.title == "Recording, today")
        #expect(project.origin == .recorded)
        #expect(project.mediaType == .audio)
        #expect(project.createdAt == started)
        #expect(project.sourceFileName == "takes/processed.caf")
        #expect(project.sourceInfo.duration == 0.5)
        #expect(project.sourceInfo.sampleRate == 48_000)
        #expect(project.trimRange == TimeRangeCodable(start: 0, duration: 0.5))
        #expect(project.recording == RecordingMetadata(
            channelNames: ["Host", "Guest 1"], editingSource: .processed, markers: [.init(time: 0.25, kind: .interruption)]
        ))
        let folder = repository.folder(for: id)
        #expect(try readSamples(folder.working).channels == readSamples(folder.takeFolder.processed).channels)
        #expect(await repository.waveformOverview(id: id)?.count == 48)
        #expect(await repository.waveformOverview(id: id)?.max() == 0.5)
        #expect(try await repository.list().map(\.project) == [project])
        #expect(!files.fileExists(atPath: folder.takeFolder.session.path()), "no longer unfinished")
        #expect(await recovery.unfinishedTakes().isEmpty)
    }

    @Test func listsOldestFirstAndTidiesUp() async throws {
        let root = try temporaryFolder()
        let repository = repository(root)
        let later = try await killedTake(in: repository, frames: 480, startedAt: started.addingTimeInterval(60))
        let earlier = try await killedTake(in: repository, frames: 480)
        let empty = try await killedTake(in: repository, frames: 0)
        let saved = try await killedTake(in: repository, frames: 480)
        try await repository.save(Project(
            id: saved, title: "Saved", mediaType: .audio, origin: .recorded, sourceFileName: "takes/processed.caf",
            sourceInfo: SourceInfo(duration: 0.01, container: "", audioCodec: "lpcm", videoCodec: nil, byteSize: 0, channelCount: 1, sampleRate: 48_000),
            createdAt: started
        ))
        let recovery = TakeRecovery(root: root, repository: repository, builder: RecordedProjectBuilder(repository: repository, inspector: AVMediaInspector()))

        #expect(await recovery.unfinishedTakes().map(\.id) == [earlier, later])
        #expect(!files.fileExists(atPath: repository.folder(for: empty).url.path()), "nothing was recorded: deleted")
        #expect(!files.fileExists(atPath: repository.folder(for: saved).takeFolder.session.path()), "the marker beside a saved project goes")
        #expect(try await repository.load(id: saved).project.title == "Saved")

        try await recovery.delete(try #require(await recovery.unfinishedTakes().first))
        #expect(!files.fileExists(atPath: repository.folder(for: earlier).url.path()))
        #expect(await recovery.unfinishedTakes().map(\.id) == [later])
    }

    @Test func aTakeWithoutAudioCantBecomeAProject() async throws {
        let repository = repository(try temporaryFolder())
        let id = try await killedTake(in: repository, frames: 0)
        let builder = RecordedProjectBuilder(repository: repository, inspector: AVMediaInspector())
        await #expect(throws: RecordingError.emptyTake) {
            try await builder.buildProject(id: id, title: "Empty", session: TakeSession(startedAt: started, channelNames: []), editingSource: .processed)
        }
    }
}
