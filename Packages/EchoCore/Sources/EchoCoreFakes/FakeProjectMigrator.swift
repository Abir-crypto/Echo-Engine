import EchoCore
import Foundation

/// Returns data unchanged and reports `storedVersion`; throws `error` when set.
public struct FakeProjectMigrator: ProjectMigrating {
    public var targetVersion: Int
    /// Reported as `fromVersion`; set above `targetVersion` to simulate a project from a newer app.
    public var storedVersion: Int
    public var error: (any Error & Sendable)?

    public init(
        targetVersion: Int = Project.currentSchemaVersion,
        storedVersion: Int = Project.currentSchemaVersion,
        error: (any Error & Sendable)? = nil
    ) {
        self.targetVersion = targetVersion
        self.storedVersion = storedVersion
        self.error = error
    }

    public func migrateIfNeeded(_ data: Data) throws -> (data: Data, didMigrate: Bool, fromVersion: Int) {
        if let error { throw error }
        return (data, false, storedVersion)
    }
}
