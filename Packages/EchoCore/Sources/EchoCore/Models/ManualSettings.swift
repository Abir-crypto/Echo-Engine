/// The live manual chain of a clip (SPEC § 8). Defaults are neutral or off.
/// Chain order: input gain → gate → EQ → de-esser → compressor → pitch shift → reverb → limiter.
public struct ManualSettings: Codable, Equatable, Sendable {
    public static let inputGainRange: ClosedRange<Float> = -24...24
    public static let pitchRange: ClosedRange<Float> = -12...12

    public var inputGainDB: Float = 0
    public var gate = Gate()
    public var eq: [EQBand] = EQBand.defaultBands
    public var deEsser = DeEsser()
    public var compressor = Compressor()
    public var pitchSemitones: Float = 0
    public var reverb = Reverb()
    public var limiter = Limiter()

    public init() {}
}

extension ManualSettings {
    public struct Gate: Codable, Equatable, Sendable {
        public static let thresholdRange: ClosedRange<Float> = -80...0

        public var isEnabled = false
        public var thresholdDB: Float = -50
        /// Attenuation applied while closed, in dB.
        public var rangeDB: Float = -40
        public var attackMs: Float = 2
        public var releaseMs: Float = 150

        public init() {}
    }

    public struct DeEsser: Codable, Equatable, Sendable {
        public static let frequencyRange: ClosedRange<Float> = 4_000...10_000

        public var isEnabled = false
        public var frequencyHz: Float = 6_500
        /// 0...1.
        public var amount: Float = 0.5

        public init() {}
    }

    public struct Compressor: Codable, Equatable, Sendable {
        public static let ratioRange: ClosedRange<Float> = 1...20

        public var isEnabled = false
        public var thresholdDB: Float = -18
        public var ratio: Float = 3
        public var attackMs: Float = 10
        public var releaseMs: Float = 120
        public var makeupDB: Float = 0

        public init() {}
    }

    public struct Reverb: Codable, Equatable, Sendable {
        public var isEnabled = false
        /// 0...1.
        public var roomSize: Float = 0.5
        /// 0...1.
        public var damping: Float = 0.5
        /// 0...1, wet/dry.
        public var mix: Float = 0.2

        public init() {}
    }

    /// Output limiter of the manual chain; always on.
    public struct Limiter: Codable, Equatable, Sendable {
        public static let ceilingRange: ClosedRange<Float> = -6...0

        public var ceilingDB: Float = -1

        public init() {}
    }
}

/// One equalizer band (SPEC § 8).
public struct EQBand: Codable, Equatable, Sendable {
    /// Filter shapes; shapes from newer app versions decode as `.unknown` and are bypassed.
    public enum Kind: String, Codable, Sendable, UnknownCaseDecodable {
        case lowShelf, peaking, highShelf
        case unknown
    }

    public static let frequencyRange: ClosedRange<Float> = 20...20_000
    public static let gainRange: ClosedRange<Float> = -18...18
    public static let qRange: ClosedRange<Float> = 0.3...8

    public var kind: Kind
    public var frequencyHz: Float
    public var gainDB: Float
    public var q: Float

    public init(kind: Kind, frequencyHz: Float, gainDB: Float = 0, q: Float) {
        self.kind = kind
        self.frequencyHz = frequencyHz
        self.gainDB = gainDB
        self.q = q
    }

    /// Flat: low shelf, four peaking bands, high shelf.
    public static let defaultBands: [EQBand] = [
        EQBand(kind: .lowShelf, frequencyHz: 80, q: 0.71),
        EQBand(kind: .peaking, frequencyHz: 250, q: 1),
        EQBand(kind: .peaking, frequencyHz: 1_000, q: 1),
        EQBand(kind: .peaking, frequencyHz: 3_000, q: 1),
        EQBand(kind: .peaking, frequencyHz: 6_000, q: 1),
        EQBand(kind: .highShelf, frequencyHz: 12_000, q: 0.71),
    ]
}
