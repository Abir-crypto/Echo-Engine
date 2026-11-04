/// Recording-specific data of a recorded project (SPEC § 5.2, § 13.3). Takes live in the project's
/// `takes/` folder: `raw.caf`, `processed.caf` and, when several channels were summed, one `ch<N>.caf` per channel.
/// Later recording features add fields here with `decodeIfPresent ?? default` (SPEC § 5.3).
public struct RecordingMetadata: Codable, Equatable, Sendable {
    /// User-given channel names in file order: `channelNames[0]` is `ch1.caf`.
    public var channelNames: [String]
    /// Which mixdown take became `working.caf`.
    public var editingSource: Take
    public var markers: [Marker]
    /// Live processing settings over the take (SPEC § 13.3), for re-processing later. Added in F11: lenient.
    public var parameterChanges: [ParameterChange]

    public init(
        channelNames: [String], editingSource: Take = .processed, markers: [Marker] = [], parameterChanges: [ParameterChange] = []
    ) {
        self.channelNames = channelNames
        self.editingSource = editingSource
        self.markers = markers
        self.parameterChanges = parameterChanges
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelNames = try container.decode([String].self, forKey: .channelNames)
        editingSource = try container.decode(Take.self, forKey: .editingSource)
        markers = try container.decode([Marker].self, forKey: .markers)
        parameterChanges = try container.decodeIfPresent([ParameterChange].self, forKey: .parameterChanges) ?? []
    }
}

extension RecordingMetadata {
    /// A mixdown take (SPEC § 13.3).
    public enum Take: String, Codable, Sendable, UnknownCaseDecodable {
        case raw, processed
        case unknown
    }

    /// A live processing setting from a point of the take on (SPEC § 13.3).
    public struct ParameterChange: Codable, Equatable, Sendable {
        public enum Parameter: String, Codable, Sendable, UnknownCaseDecodable {
            /// dB.
            case inputGain
            /// 0 Off, 1 Standard, 2 High.
            case suppression
            case unknown
        }

        /// Seconds from the start of the take.
        public var time: Double
        public var parameter: Parameter
        public var value: Double

        public init(time: Double, parameter: Parameter, value: Double) {
            self.time = time
            self.parameter = parameter
            self.value = value
        }
    }

    /// A point on the recording timeline, in seconds from the start of the take.
    public struct Marker: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable, UnknownCaseDecodable {
            /// A call or another app took the microphone (SPEC § 13.7).
            case interruption
            /// The selected input device disconnected (SPEC § 13.7).
            case routeChange
            /// Noise reduction changed to or from Standard: the audio restarted, leaving a short gap (SPEC § 13.4).
            case processingChange
            case unknown
        }

        public var time: Double
        public var kind: Kind

        public init(time: Double, kind: Kind) {
            self.time = time
            self.kind = kind
        }
    }
}
