/// What a take records, locked when it starts (SPEC § 13.2, § 13.3): which channels of the input device, in take order,
/// and how they make the mixdown. The device itself is chosen through `AudioDeviceManaging` before `prepare`.
public struct RecordingConfiguration: Equatable, Sendable {
    public enum Mixdown: Equatable, Sendable {
        /// The sum of the selected channels, each voice at its own level.
        case mono
        /// The two selected channels as left and right: the built-in mic in Stereo mode only.
        case stereo
    }

    /// Takes are written at this rate whatever the input runs at (SPEC § 13.2).
    public static let sampleRate: Double = 48_000

    /// Input channel indices (0-based) in take order: `ch1.caf` records `channels[0]`.
    public let channels: [Int]
    public let mixdown: Mixdown

    public init(channels: [Int], mixdown: Mixdown) {
        self.channels = channels
        self.mixdown = mixdown
    }

    /// The built-in mic in Stereo mode: a stereo mixdown of its left and right channels.
    public static let builtInStereo = RecordingConfiguration(channels: [0, 1], mixdown: .stereo)

    /// One mono mixdown summing `channels` (the built-in mic in Mono mode, a headset, or an interface's inputs).
    public static func mono(channels: [Int]) -> RecordingConfiguration {
        RecordingConfiguration(channels: channels, mixdown: .mono)
    }

    public var mixdownChannelCount: Int { mixdown == .stereo ? 2 : 1 }

    /// `ch<N>.caf` files are written only when 2+ channels are summed into the mono mixdown; otherwise they would
    /// duplicate `raw.caf` (user decision, SPEC § 13.3).
    public var writesChannelFiles: Bool { mixdown == .mono && channels.count >= 2 }

    /// Whether an input with `inputChannelCount` channels can record this: at least one channel, each one once and
    /// within the input, and exactly two for a stereo mixdown.
    public func isValid(forInputChannelCount inputChannelCount: Int) -> Bool {
        !channels.isEmpty && Set(channels).count == channels.count
            && channels.allSatisfy { (0..<inputChannelCount).contains($0) }
            && (mixdown == .mono || channels.count == 2)
    }
}
