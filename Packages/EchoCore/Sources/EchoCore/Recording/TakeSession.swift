import Foundation

/// Marks a take in progress (SPEC § 13.3): written when the take starts and again with each marker, removed once its
/// project is saved. Found at launch, it means the app was killed mid-take and the take can be recovered.
public struct TakeSession: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var startedAt: Date
    /// User-given channel names in take order (`RecordingMetadata.channelNames`).
    public var channelNames: [String]
    public var markers: [RecordingMetadata.Marker]

    public init(startedAt: Date, channelNames: [String], markers: [RecordingMetadata.Marker] = []) {
        schemaVersion = 1
        self.startedAt = startedAt
        self.channelNames = channelNames
        self.markers = markers
    }

    /// Lenient (SPEC § 5.3): only the start time is required.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        channelNames = try container.decodeIfPresent([String].self, forKey: .channelNames) ?? []
        markers = try container.decodeIfPresent([RecordingMetadata.Marker].self, forKey: .markers) ?? []
    }

    public func write(to folder: TakeFolder) throws {
        try JSONEncoder().encode(self).write(to: folder.session, options: .atomic)
    }

    public static func read(from folder: TakeFolder) throws -> TakeSession {
        try JSONDecoder().decode(TakeSession.self, from: Data(contentsOf: folder.session))
    }

    /// Removes the marker; nothing happens when there is none.
    public static func remove(from folder: TakeFolder) throws {
        let files = FileManager()
        guard files.fileExists(atPath: folder.session.path(percentEncoded: false)) else { return }
        try files.removeItem(at: folder.session)
    }
}
