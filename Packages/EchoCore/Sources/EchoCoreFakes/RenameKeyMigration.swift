import EchoCore

/// A migration step that renames one top-level key, for migrator and repository tests.
public struct RenameKeyMigration: ProjectMigration {
    public let from: Int
    public let oldKey: String
    public let newKey: String

    public init(from: Int, oldKey: String, newKey: String) {
        self.from = from
        self.oldKey = oldKey
        self.newKey = newKey
    }

    public func migrate(_ json: inout [String: Any]) throws {
        json[newKey] = json.removeValue(forKey: oldKey)
    }
}
