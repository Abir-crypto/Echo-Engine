import Foundation

/// Stores AI renders by `RenderKey` (SPEC § 4.3, § 6.3): ALAC 24-bit, 48 kHz, per project.
public protocol RenderCaching: Sendable {
    /// The cached render, or `nil`.
    func render(for key: RenderKey, projectID: UUID) async -> URL?
    /// Where a processor writes a render before `store` (same volume, so storing is a move).
    func temporaryURL(projectID: UUID) async throws -> URL
    /// Moves a finished render into the cache under `key`, replacing one already there, and returns its location.
    func store(_ file: URL, for key: RenderKey, projectID: UUID) async throws -> URL
    /// Every cached render of the project and its size (for the janitor, SPEC § 6.4).
    func entries(projectID: UUID) async throws -> [RenderCacheEntry]
    func remove(_ keys: Set<RenderKey>, projectID: UUID) async throws
    /// Deletes every render of the project (project deleted, Settings → Clear cache).
    func removeAll(projectID: UUID) async throws
}

public struct RenderCacheEntry: Equatable, Sendable {
    public let key: RenderKey
    public let bytes: Int64

    public init(key: RenderKey, bytes: Int64) {
        self.key = key
        self.bytes = bytes
    }
}

extension URL {
    /// `Library/Caches/Renders` (SPEC § 5.1): never backed up, safe to delete.
    public static var renderCacheDirectory: URL {
        .cachesDirectory.appending(path: "Renders", directoryHint: .isDirectory)
    }
}
