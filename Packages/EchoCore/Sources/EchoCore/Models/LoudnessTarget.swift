/// Auto Level output loudness target (SPEC § 5.2, § 6.7).
///
/// Encoded as `{"kind": …, "lufs": …}`. A kind from a newer app version decodes as `.custom` at its
/// stored loudness, so the project keeps sounding the same.
public enum LoudnessTarget: Codable, Equatable, Hashable, Sendable {
    case youtube, instagram, tiktok, spotify, podcast, appleMusic
    case custom(lufs: Double)

    /// True-peak ceiling applied after the Auto Level gain, in dBTP.
    public static let truePeakCeiling: Double = -1

    /// Integrated loudness target in LUFS.
    public var lufs: Double {
        switch self {
        case .youtube, .instagram, .tiktok, .spotify: -14
        case .podcast, .appleMusic: -16
        case .custom(let lufs): lufs
        }
    }

    private var kindName: String {
        switch self {
        case .youtube: "youtube"
        case .instagram: "instagram"
        case .tiktok: "tiktok"
        case .spotify: "spotify"
        case .podcast: "podcast"
        case .appleMusic: "appleMusic"
        case .custom: "custom"
        }
    }

    private static let platforms: [LoudnessTarget] = [.youtube, .instagram, .tiktok, .spotify, .podcast, .appleMusic]

    private enum CodingKeys: String, CodingKey {
        case kind, lufs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        if let platform = Self.platforms.first(where: { $0.kindName == kind }) {
            self = platform
        } else {
            self = .custom(lufs: try container.decode(Double.self, forKey: .lufs))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kindName, forKey: .kind)
        try container.encode(lufs, forKey: .lufs)
    }
}
