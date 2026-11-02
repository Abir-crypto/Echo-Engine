import Foundation

/// The built-in presets and the person's own (SPEC § 4.3, § 12).
public protocol PresetRepository: Sendable {
    /// Built-ins first, in their bundled order, then user presets by name.
    func list() async throws -> [Preset]
    /// Adds or replaces a user preset as given (the caller sets `updatedAt`).
    func save(_ preset: Preset) async throws
    func rename(id: UUID, to name: String) async throws
    func delete(id: UUID) async throws
}

public enum PresetError: Error, Equatable {
    /// Built-in, or saved by a newer app version.
    case readOnly
    case notFound
}

extension URL {
    /// `Library/Application Support/Presets`: one JSON file per user preset (SPEC § 5.1).
    public static var presetsDirectory: URL {
        .applicationSupportDirectory.appending(path: "Presets", directoryHint: .isDirectory)
    }
}
