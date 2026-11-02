import Foundation

/// A saved set of processing: AI stack, manual chain and Auto Level target, never the trim (SPEC § 12). Applying one
/// copies its values into the project; nothing stays linked.
///
/// Properties added after schema v1 MUST decode with `decodeIfPresent ?? default` (SPEC § 5.3).
public struct Preset: Codable, Identifiable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int = Preset.currentSchemaVersion
    public let id: UUID
    /// User presets: what the person typed. Built-ins: an English name; the app shows a localized one by `id`.
    public var name: String
    public var aiStack: [AIOperation]
    public var manual: ManualSettings
    public var outputLoudness: LoudnessTarget?
    /// Bundled with the app, read-only.
    public var isBuiltIn: Bool
    public var createdAt: Date
    /// The newer copy wins when presets are merged (SPEC § 12).
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        aiStack: [AIOperation],
        manual: ManualSettings,
        outputLoudness: LoudnessTarget?,
        isBuiltIn: Bool = false,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.aiStack = aiStack
        self.manual = manual
        self.outputLoudness = outputLoudness
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// Saved by a newer app version: shown and applied, never written back.
    public var isFromNewerVersion: Bool { schemaVersion > Self.currentSchemaVersion }
}

/// The ids of the bundled presets (SPEC § 12), fixed so projects' `basePresetID` keeps pointing at them.
public enum BuiltInPresetID {
    public static let podcastVoice = UUID(uuidString: "B0117000-0000-4000-8000-000000000001")!
    public static let outdoorVideo = UUID(uuidString: "B0117000-0000-4000-8000-000000000002")!
    public static let singing = UUID(uuidString: "B0117000-0000-4000-8000-000000000003")!
}

/// Reads the bundled presets (`BuiltInPresets.json` in the app's resources).
public enum BuiltInPresets {
    /// The presets in the file's order, all marked built-in.
    public static func load(from url: URL) throws -> [Preset] {
        try JSONDecoder().decode([Preset].self, from: Data(contentsOf: url)).map { preset in
            var preset = preset
            preset.isBuiltIn = true
            return preset
        }
    }
}
