import EchoCore
import EchoCoreFakes
@testable import EchoEngine
import Foundation
import Testing

/// Imports until cancelled.
private struct SlowImporter: MediaImporting {
    func importMedia(
        from source: URL, inspection: MediaInspection, into folder: ProjectFolder, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ImportedMedia {
        try await Task.sleep(for: .seconds(60))
        return ImportedMedia(sourceFileName: "source.mov", workingChannelCount: 2, overview: [])
    }
}

private struct PhotosError: Error {}

@MainActor
struct ImportModelTests {
    private let repository = FakeProjectRepository()
    private let clock = FakeClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    private let source = URL(filePath: "/Imports/Beach vlog.mov")
    private let inspection = MediaInspection(
        mediaType: .video,
        sourceInfo: SourceInfo(
            duration: 198, container: "com.apple.quicktime-movie", audioCodec: "aac ", videoCodec: "hvc1",
            byteSize: 800_000_000, channelCount: 2, sampleRate: 48_000
        ),
        fileExtension: "mov"
    )

    private func makeModel(
        inspectorError: ImportError? = nil,
        importer: any MediaImporting = FakeMediaImporter(),
        storage: FakeStorageEstimator = FakeStorageEstimator(importBytes: 1_000_000_000, available: 50_000_000_000)
    ) -> ImportModel {
        ImportModel(
            inspector: FakeMediaInspector(result: inspection, error: inspectorError),
            importer: importer,
            storage: storage,
            repository: repository,
            dateProvider: clock
        )
    }

    @Test func importCreatesAProjectTitledAfterTheFile() async throws {
        let model = makeModel()

        model.importFile(at: source)
        await model.waitUntilFinished()

        let project = try #require(await repository.list().first?.project)
        #expect(project.title == "Beach vlog")
        #expect(project.mediaType == .video)
        #expect(project.origin == .imported)
        #expect(project.sourceFileName == "source.mov")
        #expect(project.sourceInfo == inspection.sourceInfo)
        #expect(project.createdAt == clock.now)
        #expect(model.importedProject?.id == project.id)
        #expect(model.phase == .idle)
        #expect(model.failure == nil)
    }

    @Test func notEnoughSpaceStopsBeforeCreatingAFolder() async {
        let model = makeModel(storage: FakeStorageEstimator(importBytes: 2_400_000_000, available: 1_100_000_000))

        model.importFile(at: source)
        await model.waitUntilFinished()

        #expect(model.failure == .needsSpace(needed: 2_400_000_000, available: 1_100_000_000))
        #expect(await repository.createdFolderIDs.isEmpty)
    }

    @Test(arguments: [
        (ImportError.unsupportedFormat, ImportModel.Failure.unsupportedFormat),
        (.noAudio, .noAudio),
        (.unreadable, .unreadable),
    ])
    func inspectionErrorsBecomeMessages(_ error: ImportError, _ failure: ImportModel.Failure) async {
        let model = makeModel(inspectorError: error)

        model.importFile(at: source)
        await model.waitUntilFinished()

        #expect(model.failure == failure)
        #expect(await repository.createdFolderIDs.isEmpty)
    }

    @Test func failedImportDeletesItsFolder() async throws {
        let model = makeModel(importer: FakeMediaImporter(error: ImportError.unreadable))

        model.importFile(at: source)
        await model.waitUntilFinished()

        #expect(model.failure == .unreadable)
        let id = try #require(await repository.createdFolderIDs.first)
        #expect(!FileManager.default.fileExists(atPath: repository.folder(for: id).url.path))
        #expect(await repository.list().isEmpty)
    }

    @Test func cancellingDeletesTheFolderAndReportsNothing() async throws {
        let model = makeModel(importer: SlowImporter())

        model.importFile(at: source)
        for _ in 0..<1_000 where await repository.createdFolderIDs.isEmpty {
            await Task.yield()
        }
        model.cancel()
        await model.waitUntilFinished()

        #expect(model.failure == nil)
        #expect(model.phase == .idle)
        let id = try #require(await repository.createdFolderIDs.first)
        #expect(!FileManager.default.fileExists(atPath: repository.folder(for: id).url.path))
    }

    @Test func photosThatCantLoadAreReported() async {
        let model = makeModel()

        model.importFromPhotos { throw PhotosError() }
        await model.waitUntilFinished()
        #expect(model.failure == .photosUnavailable)

        model.importFromPhotos { nil }
        await model.waitUntilFinished()
        #expect(model.failure == .photosUnavailable)
    }

    @Test func photosCopyIsDeletedAfterImport() async throws {
        let copy = FileManager.default.temporaryDirectory.appending(path: "IMG_0420-\(UUID().uuidString).MOV")
        try Data("video".utf8).write(to: copy)
        let model = makeModel()

        model.importFromPhotos { copy }
        await model.waitUntilFinished()

        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(model.importedProject != nil)
    }
}
