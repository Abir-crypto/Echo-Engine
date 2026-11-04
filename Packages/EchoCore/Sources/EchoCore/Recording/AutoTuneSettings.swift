/// Live auto-tune (SPEC § 13.5), kept between recordings.
public struct AutoTuneSettings: Codable, Equatable, Sendable {
    public enum Scale: String, Codable, Sendable, CaseIterable {
        case major, minor
    }

    public var isOn: Bool
    /// nil: chromatic (every note); else 0 (C) … 11 (B).
    public var key: Int?
    /// Only applies with a key.
    public var scale: Scale
    /// 0 natural (retune in 100 ms) … 1 robotic (instant).
    public var style: Double
    /// 0…1: how much of a held note's own movement stays.
    public var humanize: Double
    public var preservesFormants: Bool

    public init(
        isOn: Bool = false, key: Int? = nil, scale: Scale = .major, style: Double = 0, humanize: Double = 0.5,
        preservesFormants: Bool = true
    ) {
        self.isOn = isOn
        self.key = key
        self.scale = scale
        self.style = style
        self.humanize = humanize
        self.preservesFormants = preservesFormants
    }

    /// Lenient: missing or unknown values read as the defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AutoTuneSettings()
        isOn = (try? container.decodeIfPresent(Bool.self, forKey: .isOn)) ?? defaults.isOn
        key = (try? container.decodeIfPresent(Int.self, forKey: .key)).flatMap { $0 }.flatMap { (0...11).contains($0) ? $0 : nil }
        scale = (try? container.decodeIfPresent(Scale.self, forKey: .scale)) ?? defaults.scale
        style = (try? container.decodeIfPresent(Double.self, forKey: .style)) ?? defaults.style
        humanize = (try? container.decodeIfPresent(Double.self, forKey: .humanize)) ?? defaults.humanize
        preservesFormants = (try? container.decodeIfPresent(Bool.self, forKey: .preservesFormants)) ?? defaults.preservesFormants
    }

    /// Natural ↔ Robotic as a retune time (SPEC § 13.5: 100 ms → 0 ms).
    public var retuneMs: Double { 100 * (1 - min(1, max(0, style))) }
    /// Natural from the slider's middle down.
    public var isRobotic: Bool { style > 0.5 }
}
