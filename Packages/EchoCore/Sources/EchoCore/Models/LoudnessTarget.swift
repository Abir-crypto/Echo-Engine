/// Auto Level output loudness target (SPEC § 5.2, § 6.7).
///
/// Encoded as `{"kind": …, "lufs": …}`. A kind from a newer app version decodes as `.unknown`: its stored loudness
/// still applies and its kind is written back unchanged (SPEC § 5.3).
public enum LoudnessTarget: Codable, Equatable, Hashable, Sendable {
    case youtube, instagram, tiktok, spotify, podcast, appleMusic
    case custom(lufs: Double)
    case unknown(kind: String, lufs: Double)

    /// True-peak ceiling applied after the Auto Level gain, in dBTP.
    public static let truePeakCeiling: Double = -1

    /// The platform targets with their encoded kind and loudness.
    private static let platforms: [(target: LoudnessTarget, kind: String, lufs: Double)] = [
        (.youtube, "youtube", -14), (.instagram, "instagram", -14), (.tiktok, "tiktok", -14),
        (.spotify, "spotify", -14), (.podcast, "podcast", -16), (.appleMusic, "appleMusic", -16),
    ]

    /// Integrated loudness target in LUFS.
    public var lufs: Double {
        switch self {
        case .custom(let lufs), .unknown(_, let lufs): lufs
        default: Self.platform(of: self).lufs
        }
    }

    public var isUnknown: Bool {
        if case .unknown = self { true } else { false }
    }

    private var kind: String {
        switch self {
        case .custom: "custom"
        case .unknown(let kind, _): kind
        default: Self.platform(of: self).kind
        }
    }

    /// Every platform case is in `platforms`.
    private static func platform(of target: LoudnessTarget) -> (target: LoudnessTarget, kind: String, lufs: Double) {
        platforms.first { $0.target == target }!
    }

    private enum CodingKeys: String, CodingKey {
        case kind, lufs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        if let platform = Self.platforms.first(where: { $0.kind == kind }) {
            self = platform.target
        } else if kind == "custom" {
            self = .custom(lufs: try container.decode(Double.self, forKey: .lufs))
        } else {
            self = .unknown(kind: kind, lufs: try container.decode(Double.self, forKey: .lufs))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(lufs, forKey: .lufs)
    }
}
