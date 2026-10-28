import Foundation

/// A project manifest, stored as `project.json` in the project folder (SPEC § 5.1–5.3).
///
/// Properties added after schema v1 MUST decode with `decodeIfPresent ?? default`; additive changes do
/// not bump `currentSchemaVersion`.
public struct Project: Codable, Identifiable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int = Project.currentSchemaVersion
    public let id: UUID
    public var title: String
    public var mediaType: MediaType
    public var origin: ProjectOrigin
    /// File name inside the project folder, e.g. `source.mov`.
    public var sourceFileName: String
    public var sourceInfo: SourceInfo
    /// Applied at playback and export only.
    public var trimRange: TimeRangeCodable
    /// v1: exactly one clip covering the full source.
    public var clips: [Clip]
    /// Auto Level target; `nil` = off.
    public var outputLoudness: LoudnessTarget?
    public var basePresetID: UUID?
    /// Present for recorded projects.
    public var recording: RecordingMetadata?
    public var createdAt: Date
    public var updatedAt: Date

    /// A new project with one clip and the trim covering the full source.
    public init(
        id: UUID = UUID(),
        title: String,
        mediaType: MediaType,
        origin: ProjectOrigin,
        sourceFileName: String,
        sourceInfo: SourceInfo,
        recording: RecordingMetadata? = nil,
        createdAt: Date
    ) {
        let fullRange = TimeRangeCodable.full(duration: sourceInfo.duration)
        self.id = id
        self.title = title
        self.mediaType = mediaType
        self.origin = origin
        self.sourceFileName = sourceFileName
        self.sourceInfo = sourceInfo
        self.trimRange = fullRange
        self.clips = [Clip(sourceRange: fullRange)]
        self.outputLoudness = nil
        self.basePresetID = nil
        self.recording = recording
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

/// Media types from newer app versions decode as `.unknown`.
public enum MediaType: String, Codable, Sendable, UnknownCaseDecodable {
    case audio, video
    case unknown
}

/// Origins from newer app versions decode as `.unknown`.
public enum ProjectOrigin: String, Codable, Sendable, UnknownCaseDecodable {
    case imported, recorded
    case unknown
}
