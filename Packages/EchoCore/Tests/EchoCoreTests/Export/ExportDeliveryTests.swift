@testable import EchoCore
import EchoCoreFakes
import Foundation
import Testing

final class ExportWorkspaceTests {
    private let root: URL

    init() {
        root = FileManager.default.temporaryDirectory.appending(path: "Exports-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @Test func eachExportGetsItsOwnFolderAndRemovesIt() throws {
        let workspace = ExportWorkspace(root: root)
        let first = try workspace.makeFolder()
        let second = try workspace.makeFolder()
        #expect(first != second)
        #expect(first.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        try Data("audio".utf8).write(to: first.appending(path: "Interview.m4a"))

        workspace.remove(first)

        #expect(!FileManager.default.fileExists(atPath: first.path()))
        #expect(FileManager.default.fileExists(atPath: second.path()))
    }

    @Test func leftoversOfUnfinishedExportsAreRemoved() throws {
        let workspace = ExportWorkspace(root: root)
        let folder = try workspace.makeFolder()
        try Data("video".utf8).write(to: folder.appending(path: "Clip.mov"))

        workspace.removeAll()

        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path()).isEmpty)
    }

    @Test func removingWithNothingThereIsFine() {
        ExportWorkspace(root: root).removeAll()
        #expect(!FileManager.default.fileExists(atPath: root.path()))
    }
}

struct ExportFileNameTests {
    private func name(_ title: String) -> String {
        ExportWorkspace.fileName(title: title, fallback: "Export", fileExtension: "m4a")
    }

    @Test func theTitleNamesTheFile() {
        #expect(name("Interview") == "Interview.m4a")
        #expect(name("مقابلة") == "مقابلة.m4a")
    }

    @Test func pathCharactersAreReplaced() {
        #expect(name("Take 1/2: final") == "Take 1-2- final.m4a")
    }

    @Test func leadingDotsAndSpacesAreDropped() {
        #expect(name("  ..hidden  ") == "hidden.m4a")
        #expect(name("a\nb") == "a b.m4a")
    }

    @Test func anEmptyTitleUsesTheFallback() {
        #expect(name("") == "Export.m4a")
        #expect(name(" / ") == "-.m4a")
        #expect(name(" . ") == "Export.m4a")
    }

    @Test func longTitlesAreCutAtACharacter() {
        let result = name(String(repeating: "🎙", count: 100))
        #expect(result.utf8.count <= ExportWorkspace.maximumFileNameBytes)
        #expect(result.hasSuffix("🎙.m4a"), "never half a character")
    }
}

struct PhotosDestinationTests {
    private let video = URL(filePath: "/tmp/Exports/x/Holiday.mov")

    @Test func theVideoIsMovedIntoPhotos() async throws {
        let library = FakePhotoLibrary()
        let destination = PhotosDestination(library: library)

        #expect(destination.kind == .photos)
        #expect(try await destination.deliver(video) == .delivered)
        #expect(await library.added == [video])
    }

    @Test func deniedAccessIsReported() async throws {
        let library = FakePhotoLibrary(grantsAccess: false)

        await #expect(throws: ExportError.photoLibraryDenied) {
            try await PhotosDestination(library: library).deliver(video)
        }
        #expect(await library.added.isEmpty)
    }

    @Test func aFailedSaveIsReported() async throws {
        let library = FakePhotoLibrary()
        await library.setFailure(CocoaError(.fileWriteOutOfSpace))

        await #expect(throws: ExportError.photoLibraryFailed) {
            try await PhotosDestination(library: library).deliver(video)
        }
    }
}
