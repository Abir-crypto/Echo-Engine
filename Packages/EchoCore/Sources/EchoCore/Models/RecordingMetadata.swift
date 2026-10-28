/// Recording-specific data of a recorded project (SPEC § 5.2, § 13.3). Takes live in the project's
/// `takes/` folder: `raw.caf`, `processed.caf` and one `ch<N>.caf` per channel.
/// Later recording features add fields here with `decodeIfPresent ?? default` (SPEC § 5.3).
public struct RecordingMetadata: Codable, Equatable, Sendable {
    /// User-given channel names in file order: `channelNames[0]` is `ch1.caf`.
    public var channelNames: [String]
    /// Which mixdown take became `working.caf`.
    public var editingSource: Take
    public var markers: [Marker]

    public init(channelNames: [String], editingSource: Take = .processed, markers: [Marker] = []) {
        self.channelNames = channelNames
        self.editingSource = editingSource
        self.markers = markers
    }
}

extension RecordingMetadata {
    /// A mixdown take (SPEC § 13.3).
    public enum Take: String, Codable, Sendable, UnknownCaseDecodable {
        case raw, processed
        case unknown
    }

    /// A point on the recording timeline, in seconds from the start of the take.
    public struct Marker: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable, UnknownCaseDecodable {
            /// A call or another app took the microphone (SPEC § 13.7).
            case interruption
            /// The selected input device disconnected (SPEC § 13.7).
            case routeChange
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
