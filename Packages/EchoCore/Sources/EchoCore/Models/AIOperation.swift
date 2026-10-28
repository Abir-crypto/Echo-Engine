import Foundation

/// An AI enhancement. Features from newer app versions decode as `.unknown` (SPEC § 5.2–5.3).
public enum AIFeature: String, Codable, CaseIterable, Sendable, UnknownCaseDecodable {
    case noiseSuppression, clearVoice, voiceLeveler
    case unknown
}

/// One step of a clip's AI stack (SPEC § 5.2).
public struct AIOperation: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var kind: AIFeature
    /// 0...1, wet/dry.
    public var strength: Float

    /// The raw kind of an `.unknown` operation, written back unchanged so a feature from a newer
    /// app version survives being saved by this one ("ops with .unknown are kept", SPEC § 5.3).
    private var unknownKindRawValue: String?

    public init(id: UUID = UUID(), kind: AIFeature, strength: Float) {
        self.id = id
        self.kind = kind
        self.strength = strength
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, strength
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        strength = try container.decode(Float.self, forKey: .strength)
        let rawKind = try container.decode(String.self, forKey: .kind)
        kind = AIFeature(rawValue: rawKind) ?? .unknown
        unknownKindRawValue = kind == .unknown ? rawKind : nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(strength, forKey: .strength)
        let rawKind = kind == .unknown ? (unknownKindRawValue ?? kind.rawValue) : kind.rawValue
        try container.encode(rawKind, forKey: .kind)
    }
}
