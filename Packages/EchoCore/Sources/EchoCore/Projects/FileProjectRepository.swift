import Foundation

/// Stores each project in `<root>/<UUID>/` (SPEC § 5.1). File work runs on this actor, off the main thread.
public actor FileProjectRepository: ProjectRepository {
    private let root: URL
    private let migrator: any ProjectMigrating
    private let clock: any DateProviding
    private let fileManager = FileManager()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public init(root: URL, migrator: any ProjectMigrating, clock: any DateProviding = SystemClock()) {
        self.root = root
        self.migrator = migrator
        self.clock = clock
    }

    public nonisolated func folder(for id: UUID) -> ProjectFolder {
        ProjectFolder(url: root.appending(path: id.uuidString, directoryHint: .isDirectory))
    }

    public func list() throws -> [StoredProject] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let ids = try fileManager.contentsOfDirectory(atPath: root.path).compactMap(UUID.init(uuidString:))
        return ids.compactMap { try? load(id: $0) }
            .sorted { $0.project.updatedAt > $1.project.updatedAt }
    }

    public func load(id: UUID) throws -> StoredProject {
        let manifest = folder(for: id).manifest
        guard fileManager.fileExists(atPath: manifest.path) else { throw ProjectRepositoryError.notFound }
        let migration = try migrator.migrateFileIfNeeded(at: manifest)
        let project = try JSONDecoder().decode(Project.self, from: migration.data)
        return StoredProject(project: project, isReadOnly: migrator.isReadOnly(schemaVersion: migration.fromVersion))
    }

    public func save(_ project: Project) throws {
        guard !migrator.isReadOnly(schemaVersion: project.schemaVersion) else { throw ProjectRepositoryError.readOnly }
        let folder = try createFolder(for: project.id)
        try encoder.encode(project).write(to: folder.manifest, options: .atomic)
    }

    public func createFolder(for id: UUID) throws -> ProjectFolder {
        let folder = folder(for: id)
        try fileManager.createDirectory(at: folder.url, withIntermediateDirectories: true)
        var url = folder.url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return folder
    }

    public func rename(id: UUID, to title: String) throws {
        let stored = try load(id: id)
        guard !stored.isReadOnly else { throw ProjectRepositoryError.readOnly }
        var project = stored.project
        project.title = title
        project.updatedAt = clock.now
        try save(project)
    }

    public func delete(id: UUID) throws {
        let folder = folder(for: id)
        guard fileManager.fileExists(atPath: folder.url.path) else { throw ProjectRepositoryError.notFound }
        try fileManager.removeItem(at: folder.url)
    }

    public func diskUsage(id: UUID) throws -> Int64 {
        let folder = folder(for: id)
        guard fileManager.fileExists(atPath: folder.url.path) else { throw ProjectRepositoryError.notFound }
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let files = fileManager.enumerator(at: folder.url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
