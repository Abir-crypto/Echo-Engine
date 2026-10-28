import Foundation

/// Lists, loads, saves, renames and deletes project folders (SPEC § 4.3, § 5).
public protocol ProjectRepository: Sendable {
    /// Every readable project, most recently updated first. Folders without a readable manifest (for example
    /// an import in progress) are skipped.
    func list() async throws -> [StoredProject]
    /// Migrates the manifest if needed, then decodes it.
    func load(id: UUID) async throws -> StoredProject
    /// Writes the manifest atomically, creating the folder if needed.
    /// Throws `ProjectRepositoryError.readOnly` for projects written by a newer app version.
    func save(_ project: Project) async throws
    /// Creates the project folder and excludes it, with everything later written into it, from backup
    /// (SPEC § 5.1). Call before writing any file into a new project. Idempotent.
    func createFolder(for id: UUID) async throws -> ProjectFolder
    /// Changes the title only; the folder keeps its UUID name. Updates `updatedAt`.
    func rename(id: UUID, to title: String) async throws
    func delete(id: UUID) async throws
    /// Bytes the project folder occupies on disk (manifest, media, takes, thumbnail): what deleting it frees,
    /// apart from its renders.
    func diskUsage(id: UUID) async throws -> Int64
    func folder(for id: UUID) -> ProjectFolder
}

/// A project as read from disk.
public struct StoredProject: Equatable, Sendable {
    public var project: Project
    /// Written by a newer app version: show "Update Echo Engine to edit this project", never save (SPEC § 5.3).
    public var isReadOnly: Bool

    public init(project: Project, isReadOnly: Bool) {
        self.project = project
        self.isReadOnly = isReadOnly
    }
}

public enum ProjectRepositoryError: Error, Equatable {
    case notFound
    /// The project was written by a newer app version.
    case readOnly
}
