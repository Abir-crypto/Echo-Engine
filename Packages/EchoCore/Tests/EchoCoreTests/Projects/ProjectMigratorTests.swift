import EchoCore
import EchoCoreFakes
import Foundation
import Testing

/// v1 → v2: renames `name` to `title`.
private let renameNameToTitle = RenameKeyMigration(from: 1, oldKey: "name", newKey: "title")

/// v2 → v3: adds `tags`.
private struct AddTags: ProjectMigration {
    let from = 2
    func migrate(_ json: inout [String: Any]) throws {
        json["tags"] = [String]()
    }
}

private struct FailingMigration: ProjectMigration {
    struct Failure: Error {}
    let from = 1
    func migrate(_ json: inout [String: Any]) throws {
        throw Failure()
    }
}

struct ProjectMigratorTests {
    /// Migrations deliberately registered out of order.
    private let migrator = ProjectMigrator(targetVersion: 3, migrations: [AddTags(), renameNameToTitle])

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func chainsMigrationsInVersionOrder() throws {
        let result = try migrator.migrateIfNeeded(Data(#"{"schemaVersion":1,"name":"Beach vlog"}"#.utf8))
        let json = try object(result.data)
        #expect(result.didMigrate)
        #expect(result.fromVersion == 1)
        #expect(json["schemaVersion"] as? Int == 3)
        #expect(json["title"] as? String == "Beach vlog")
        #expect(json["name"] == nil)
        #expect(json["tags"] as? [String] == [])
    }

    @Test func startsFromTheStoredVersion() throws {
        let result = try migrator.migrateIfNeeded(Data(#"{"schemaVersion":2,"title":"Beach vlog"}"#.utf8))
        let json = try object(result.data)
        #expect(result.fromVersion == 2)
        #expect(json["title"] as? String == "Beach vlog")
        #expect(json["tags"] as? [String] == [])
    }

    @Test func missingSchemaVersionCountsAsVersionOne() throws {
        let result = try migrator.migrateIfNeeded(Data(#"{"name":"Old"}"#.utf8))
        #expect(result.fromVersion == 1)
        #expect(try object(result.data)["title"] as? String == "Old")
    }

    @Test func missingVersionAtTheTargetIsFilledInWithoutMigrating() throws {
        let result = try ProjectMigrator(targetVersion: 1, migrations: []).migrateIfNeeded(Data(#"{"title":"Old"}"#.utf8))
        #expect(!result.didMigrate)
        #expect(try object(result.data)["schemaVersion"] as? Int == 1)
    }

    @Test func currentDataIsReturnedUnchanged() throws {
        let data = Data(#"{"schemaVersion":3,"title":"Beach vlog"}"#.utf8)
        let result = try migrator.migrateIfNeeded(data)
        #expect(!result.didMigrate)
        #expect(result.fromVersion == 3)
        #expect(result.data == data)
    }

    @Test func newerSchemaIsUnchangedAndReadOnly() throws {
        let data = Data(#"{"schemaVersion":5}"#.utf8)
        let result = try migrator.migrateIfNeeded(data)
        #expect(!result.didMigrate)
        #expect(result.data == data)
        #expect(migrator.isReadOnly(schemaVersion: result.fromVersion))
        #expect(!migrator.isReadOnly(schemaVersion: 3))
    }

    @Test func gapInTheChainThrows() {
        let incomplete = ProjectMigrator(targetVersion: 3, migrations: [renameNameToTitle])
        #expect(throws: ProjectMigrationError.missingMigration(from: 2)) {
            try incomplete.migrateIfNeeded(Data(#"{"schemaVersion":1}"#.utf8))
        }
    }

    @Test(arguments: ["not json", #"["array"]"#])
    func nonObjectDataThrows(_ text: String) {
        #expect(throws: ProjectMigrationError.invalidJSON) {
            try migrator.migrateIfNeeded(Data(text.utf8))
        }
    }

    @Test func v1AppHasNothingToMigrate() throws {
        let project = Project(
            title: "Beach vlog", mediaType: .video, origin: .imported, sourceFileName: "source.mov",
            sourceInfo: SourceInfo(
                duration: 10, container: "com.apple.quicktime-movie", audioCodec: "aac ", videoCodec: "hvc1",
                byteSize: 1_000, channelCount: 2, sampleRate: 48_000
            ),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let result = try ProjectMigrator().migrateIfNeeded(JSONEncoder().encode(project))
        #expect(!result.didMigrate)
        #expect(result.fromVersion == ProjectMigrator.currentVersion)
    }
}

struct ProjectFileMigrationTests {
    private let migrator = ProjectMigrator(targetVersion: 3, migrations: [renameNameToTitle, AddTags()])

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func writesBackupOfOriginalThenMigratedFile() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectFile = folder.appending(path: "project.json")
        let original = Data(#"{"schemaVersion":1,"name":"Beach vlog"}"#.utf8)
        try original.write(to: projectFile)

        let result = try migrator.migrateFileIfNeeded(at: projectFile)

        #expect(result.didMigrate)
        #expect(try Data(contentsOf: folder.appending(path: "project.v1.backup.json")) == original)
        #expect(try Data(contentsOf: projectFile) == result.data)
    }

    @Test func currentFileIsLeftAloneWithoutBackup() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectFile = folder.appending(path: "project.json")
        let original = Data(#"{"schemaVersion":3,"title":"Beach vlog"}"#.utf8)
        try original.write(to: projectFile)

        let result = try migrator.migrateFileIfNeeded(at: projectFile)

        #expect(!result.didMigrate)
        #expect(try Data(contentsOf: projectFile) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["project.json"])
    }

    @Test func failedMigrationLeavesTheFileUntouched() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectFile = folder.appending(path: "project.json")
        let original = Data(#"{"schemaVersion":1,"name":"Beach vlog"}"#.utf8)
        try original.write(to: projectFile)

        let failing = ProjectMigrator(targetVersion: 2, migrations: [FailingMigration()])
        #expect(throws: FailingMigration.Failure.self) {
            try failing.migrateFileIfNeeded(at: projectFile)
        }
        #expect(try Data(contentsOf: projectFile) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["project.json"])
    }
}
