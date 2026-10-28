import EchoCore
import EchoCoreFakes
import Foundation
import Testing


final class FileProjectRepositoryTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "Projects-\(UUID().uuidString)")
    private let clock = FakeClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    private lazy var repository = FileProjectRepository(root: root, migrator: ProjectMigrator(), clock: clock)

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func project(title: String = "Beach vlog", updatedAt: TimeInterval = 1_793_000_000) -> Project {
        var project = Project(
            title: title, mediaType: .video, origin: .imported, sourceFileName: "source.mov",
            sourceInfo: SourceInfo(
                duration: 30, container: "com.apple.quicktime-movie", audioCodec: "aac ", videoCodec: "hvc1",
                byteSize: 1_000, channelCount: 2, sampleRate: 48_000
            ),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        project.updatedAt = Date(timeIntervalSince1970: updatedAt)
        return project
    }

    /// Writes a manifest directly, bypassing `save`, after editing its JSON.
    private func writeManifest(_ project: Project, edit: (inout [String: Any]) -> Void) throws {
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        edit(&json)
        let folder = repository.folder(for: project.id)
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: folder.manifest)
    }

    @Test func savedProjectLoadsBackFromItsUUIDFolder() async throws {
        let project = project()
        try await repository.save(project)

        #expect(FileManager.default.fileExists(atPath: root.appending(path: "\(project.id.uuidString)/project.json").path))
        let stored = try await repository.load(id: project.id)
        #expect(stored.project == project)
        #expect(!stored.isReadOnly)
    }

    @Test func listIsSortedByMostRecentlyUpdated() async throws {
        let older = project(title: "Older", updatedAt: 1_000)
        let newest = project(title: "Newest", updatedAt: 3_000)
        let middle = project(title: "Middle", updatedAt: 2_000)
        for project in [older, newest, middle] {
            try await repository.save(project)
        }

        #expect(try await repository.list().map(\.project.title) == ["Newest", "Middle", "Older"])
    }

    @Test func listSkipsFoldersWithoutAReadableManifest() async throws {
        let valid = project()
        try await repository.save(valid)
        let importing = root.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: importing, withIntermediateDirectories: true)
        let corrupt = repository.folder(for: UUID())
        try FileManager.default.createDirectory(at: corrupt.url, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: corrupt.manifest)
        try Data().write(to: root.appending(path: ".DS_Store"))

        #expect(try await repository.list().map(\.project.id) == [valid.id])
    }

    @Test func listIsEmptyBeforeTheFirstProject() async throws {
        #expect(try await repository.list().isEmpty)
    }

    @Test func renameChangesTitleAndUpdatedAt() async throws {
        let project = project()
        try await repository.save(project)

        try await repository.rename(id: project.id, to: "Sunset vlog")

        let renamed = try await repository.load(id: project.id).project
        #expect(renamed.title == "Sunset vlog")
        #expect(renamed.updatedAt == clock.now)
        #expect(renamed.sourceFileName == project.sourceFileName)
    }

    @Test func deleteRemovesTheFolder() async throws {
        let project = project()
        try await repository.save(project)

        try await repository.delete(id: project.id)

        #expect(!FileManager.default.fileExists(atPath: repository.folder(for: project.id).url.path))
        await #expect(throws: ProjectRepositoryError.notFound) { try await repository.load(id: project.id) }
        await #expect(throws: ProjectRepositoryError.notFound) { try await repository.delete(id: project.id) }
    }

    private func isExcludedFromBackup(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }

    @Test func saveExcludesTheWholeProjectFolderFromBackup() async throws {
        let project = project()
        try await repository.save(project)

        #expect(try isExcludedFromBackup(repository.folder(for: project.id).url))
    }

    @Test func createFolderMakesAnExcludedFolderAndIsIdempotent() async throws {
        let id = UUID()
        let folder = try await repository.createFolder(for: id)
        try Data("video".utf8).write(to: folder.source(fileName: "source.mov"))

        #expect(try await repository.createFolder(for: id) == folder)
        #expect(try isExcludedFromBackup(folder.url))
        #expect(FileManager.default.fileExists(atPath: folder.source(fileName: "source.mov").path))
    }

    @Test func diskUsageCountsEveryFileInTheFolder() async throws {
        let project = project()
        let folder = try await repository.createFolder(for: project.id)
        try FileManager.default.createDirectory(at: folder.takes, withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: folder.source(fileName: project.sourceFileName))
        try Data(count: 50_000).write(to: folder.takes.appending(path: "raw.caf"))
        try await repository.save(project)

        let usage = try await repository.diskUsage(id: project.id)

        #expect(usage >= 150_000)
        #expect(usage < 400_000)
        await #expect(throws: ProjectRepositoryError.notFound) { try await repository.diskUsage(id: UUID()) }
    }

    @Test func newerSchemaProjectIsReadOnly() async throws {
        let project = project()
        try writeManifest(project) { $0["schemaVersion"] = Project.currentSchemaVersion + 1 }
        let original = try Data(contentsOf: repository.folder(for: project.id).manifest)

        let stored = try await repository.load(id: project.id)

        #expect(stored.isReadOnly)
        await #expect(throws: ProjectRepositoryError.readOnly) { try await repository.save(stored.project) }
        await #expect(throws: ProjectRepositoryError.readOnly) { try await repository.rename(id: project.id, to: "New") }
        #expect(try Data(contentsOf: repository.folder(for: project.id).manifest) == original)
    }

    @Test func valuesFromANewerAppMakeTheProjectReadOnly() async throws {
        let project = project()
        try writeManifest(project) { $0["mediaType"] = "hologram" }

        let stored = try await repository.load(id: project.id)

        #expect(stored.project.mediaType == .unknown)
        #expect(stored.isReadOnly)
        await #expect(throws: ProjectRepositoryError.readOnly) { try await repository.save(stored.project) }
    }

    @Test func manifestWithoutSchemaVersionLoadsAsVersionOne() async throws {
        let project = project()
        try writeManifest(project) { $0.removeValue(forKey: "schemaVersion") }

        let stored = try await repository.load(id: project.id)

        #expect(stored.project.schemaVersion == 1)
        #expect(!stored.isReadOnly)
    }

    @Test func olderSchemaIsMigratedAndBackedUpOnLoad() async throws {
        let project = project()
        let migrating = FileProjectRepository(
            root: root, migrator: ProjectMigrator(targetVersion: 2, migrations: [RenameKeyMigration(from: 1, oldKey: "name", newKey: "title")]), clock: clock
        )
        try writeManifest(project) { json in
            json["schemaVersion"] = 1
            json["name"] = json.removeValue(forKey: "title")
        }

        let stored = try await migrating.load(id: project.id)

        #expect(stored.project.title == "Beach vlog")
        #expect(stored.project.schemaVersion == 2)
        #expect(!stored.isReadOnly)
        let backup = migrating.folder(for: project.id).url.appending(path: "project.v1.backup.json")
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }
}
