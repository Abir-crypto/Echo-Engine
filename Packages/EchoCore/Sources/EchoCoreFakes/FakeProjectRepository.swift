import EchoCore
import Foundation

/// In-memory manifests for previews and model tests. `createFolder` makes a real temporary folder so importers
/// have somewhere to write.
public actor FakeProjectRepository: ProjectRepository {
    public private(set) var stored: [UUID: StoredProject]
    /// Successful `save` calls, including those made by `rename`.
    public private(set) var saveCount = 0
    /// Folders made by `createFolder`, in order.
    public private(set) var createdFolderIDs: [UUID] = []
    /// Reported by `diskUsage(id:)`; 0 when missing.
    public var diskUsageByID: [UUID: Int64]
    public var overviewsByID: [UUID: [Float]]
    public var thumbnailsByID: [UUID: Data]
    private let clock: any DateProviding

    public init(
        projects: [Project] = [],
        readOnlyIDs: Set<UUID> = [],
        diskUsageByID: [UUID: Int64] = [:],
        overviewsByID: [UUID: [Float]] = [:],
        thumbnailsByID: [UUID: Data] = [:],
        clock: any DateProviding = FakeClock()
    ) {
        stored = Dictionary(uniqueKeysWithValues: projects.map {
            ($0.id, StoredProject(project: $0, isReadOnly: readOnlyIDs.contains($0.id)))
        })
        self.diskUsageByID = diskUsageByID
        self.overviewsByID = overviewsByID
        self.thumbnailsByID = thumbnailsByID
        self.clock = clock
    }

    public nonisolated func folder(for id: UUID) -> ProjectFolder {
        ProjectFolder(url: FileManager.default.temporaryDirectory.appending(path: "FakeProjects/\(id.uuidString)"))
    }

    public func list() -> [StoredProject] {
        stored.values.sorted { $0.project.updatedAt > $1.project.updatedAt }
    }

    public func load(id: UUID) throws -> StoredProject {
        guard let project = stored[id] else { throw ProjectRepositoryError.notFound }
        return project
    }

    public func save(_ project: Project) throws {
        guard stored[project.id]?.isReadOnly != true, !project.containsUnknownValues else {
            throw ProjectRepositoryError.readOnly
        }
        stored[project.id] = StoredProject(project: project, isReadOnly: false)
        saveCount += 1
    }

    public func createFolder(for id: UUID) throws -> ProjectFolder {
        let folder = folder(for: id)
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        createdFolderIDs.append(id)
        return folder
    }

    public func rename(id: UUID, to title: String) throws {
        var project = try load(id: id).project
        project.title = title
        project.updatedAt = clock.now
        try save(project)
    }

    /// Removes the manifest and the folder; a folder without a manifest (an import in progress) counts too.
    public func delete(id: UUID) throws {
        let hadManifest = stored.removeValue(forKey: id) != nil
        let folder = folder(for: id).url
        let hadFolder = FileManager.default.fileExists(atPath: folder.path)
        if hadFolder {
            try FileManager.default.removeItem(at: folder)
        }
        guard hadManifest || hadFolder else { throw ProjectRepositoryError.notFound }
    }

    public func waveformOverview(id: UUID) -> [Float]? {
        overviewsByID[id]
    }

    public func thumbnail(id: UUID) -> Data? {
        thumbnailsByID[id]
    }

    public func diskUsage(id: UUID) throws -> Int64 {
        guard stored[id] != nil else { throw ProjectRepositoryError.notFound }
        return diskUsageByID[id] ?? 0
    }
}
