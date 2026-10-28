import Foundation

/// Brings raw `project.json` data up to the schema this app writes (SPEC § 5.3).
public protocol ProjectMigrating: Sendable {
    /// The schema version this app reads and writes.
    var targetVersion: Int { get }

    /// Runs chained `vN → vN+1` migrations on raw JSON, before decoding. Data already at (or newer than)
    /// `targetVersion` is returned unchanged with `didMigrate == false`.
    func migrateIfNeeded(_ data: Data) throws -> (data: Data, didMigrate: Bool, fromVersion: Int)
}

/// One schema step, `from → from + 1`. The migrator sets `schemaVersion` after each step.
public protocol ProjectMigration: Sendable {
    var from: Int { get }
    func migrate(_ json: inout [String: Any]) throws
}

public enum ProjectMigrationError: Error, Equatable {
    /// The data is not a JSON object.
    case invalidJSON
    /// No migration is registered for this source version.
    case missingMigration(from: Int)
}

extension ProjectMigrating {
    /// Projects written by a newer app version open read-only and are never saved (SPEC § 5.3).
    public func isReadOnly(schemaVersion: Int) -> Bool {
        schemaVersion > targetVersion
    }

    /// Migrates the `project.json` at `projectFile` in place. Before writing the migrated file it writes the
    /// original bytes to `project.v<old>.backup.json` next to it. Both writes are atomic.
    public func migrateFileIfNeeded(at projectFile: URL) throws -> (data: Data, didMigrate: Bool, fromVersion: Int) {
        let original = try Data(contentsOf: projectFile)
        let result = try migrateIfNeeded(original)
        if result.didMigrate {
            let backup = projectFile.deletingLastPathComponent()
                .appending(path: ProjectMigrator.backupFileName(fromVersion: result.fromVersion))
            try original.write(to: backup, options: .atomic)
            try result.data.write(to: projectFile, options: .atomic)
        }
        return result
    }
}
