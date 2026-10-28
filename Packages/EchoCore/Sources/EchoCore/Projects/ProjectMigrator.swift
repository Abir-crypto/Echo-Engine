import Foundation

/// Runs the registered schema migrations in order (SPEC § 5.3).
public final class ProjectMigrator: ProjectMigrating {
    public static let currentVersion = Project.currentSchemaVersion

    /// v1 has no migrations. Add one `ProjectMigration` per schema bump.
    public static let registeredMigrations: [any ProjectMigration] = []

    public let targetVersion: Int
    private let migrations: [any ProjectMigration]

    public init(
        targetVersion: Int = ProjectMigrator.currentVersion,
        migrations: [any ProjectMigration] = ProjectMigrator.registeredMigrations
    ) {
        self.targetVersion = targetVersion
        self.migrations = migrations
    }

    /// `project.v<N>.backup.json`, written before migrating away from version N.
    public static func backupFileName(fromVersion version: Int) -> String {
        "project.v\(version).backup.json"
    }

    public func migrateIfNeeded(_ data: Data) throws -> (data: Data, didMigrate: Bool, fromVersion: Int) {
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProjectMigrationError.invalidJSON
        }
        let fromVersion = json[Self.versionKey] as? Int ?? 1
        guard fromVersion < targetVersion else {
            return (data, false, fromVersion)
        }
        for version in fromVersion..<targetVersion {
            guard let migration = migrations.first(where: { $0.from == version }) else {
                throw ProjectMigrationError.missingMigration(from: version)
            }
            try migration.migrate(&json)
            json[Self.versionKey] = version + 1
        }
        let migrated = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return (migrated, true, fromVersion)
    }

    private static let versionKey = "schemaVersion"
}
