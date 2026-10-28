import EchoCore
import Foundation

/// In-memory projects for previews and model tests.
public actor FakeProjectRepository: ProjectRepository {
    public private(set) var stored: [UUID: StoredProject]
    private let clock: any DateProviding

    public init(projects: [Project] = [], readOnlyIDs: Set<UUID> = [], clock: any DateProviding = FakeClock()) {
        stored = Dictionary(uniqueKeysWithValues: projects.map {
            ($0.id, StoredProject(project: $0, isReadOnly: readOnlyIDs.contains($0.id)))
        })
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
        guard stored[project.id]?.isReadOnly != true else { throw ProjectRepositoryError.readOnly }
        stored[project.id] = StoredProject(project: project, isReadOnly: false)
    }

    public func createFolder(for id: UUID) throws -> ProjectFolder {
        let folder = folder(for: id)
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        return folder
    }

    public func rename(id: UUID, to title: String) throws {
        var project = try load(id: id).project
        project.title = title
        project.updatedAt = clock.now
        try save(project)
    }

    public func delete(id: UUID) throws {
        guard stored.removeValue(forKey: id) != nil else { throw ProjectRepositoryError.notFound }
    }
}
