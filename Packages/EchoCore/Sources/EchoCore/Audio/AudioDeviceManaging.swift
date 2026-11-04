/// Audio session, inputs, channels, latency and route changes (SPEC § 4.3, § 13.2). The editor needs playback only;
/// recording adds inputs and routes in F10.
@MainActor
public protocol AudioDeviceManaging: AnyObject {
    /// Configures and activates the session for editor playback (plays with the silent switch on).
    func activateForPlayback() throws
    /// Session changes playback must react to. Each call returns a new stream; it ends when its consumer stops.
    func sessionEvents() -> AsyncStream<AudioSessionEvent>
    /// `.playAndRecord` with Bluetooth (HFP and A2DP) and the speaker by default, 48 kHz (SPEC § 13.2).
    func activateForRecording() throws
    /// Every input iOS offers now; one can record at a time (SPEC § 13.2).
    func availableInputs() -> [AudioInput]
    /// Makes `id` the input; the built-in mic records mono or stereo (where supported).
    func selectInput(id: String, builtInMode: BuiltInMicMode) throws
    /// The current route's latencies, for backing-track compensation (SPEC § 13.6).
    var latency: AudioLatency { get }
    /// Channels the selected input offers (an interface often reports them only once selected), for step 2 of the
    /// device sheet (SPEC § 13.2).
    var selectedInputChannelCount: Int { get }
    /// The input the session records from right now (`AudioInput.id`); nil without one.
    var currentInputID: String? { get }
}

/// An input the person can record from (SPEC § 13.2). Its name is the device's and only shown in the app.
public struct AudioInput: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case builtInMic, headsetMic, usb, bluetooth, other
    }

    public let id: String
    public let name: String
    public let kind: Kind
    public let channelCount: Int
    /// The built-in mic of some devices records stereo.
    public let supportsStereo: Bool

    public init(id: String, name: String, kind: Kind, channelCount: Int, supportsStereo: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.channelCount = channelCount
        self.supportsStereo = supportsStereo
    }

    /// Bluetooth: "Higher delay, not ideal with auto-tune or backing tracks" (SPEC § 13.2).
    public var hasHigherDelay: Bool { kind == .bluetooth }
}

public enum BuiltInMicMode: String, Codable, Sendable {
    case mono, stereo
}

/// Route latencies in seconds (SPEC § 13.6).
public struct AudioLatency: Equatable, Sendable {
    public let inputSeconds: Double
    public let outputSeconds: Double
    public let ioBufferSeconds: Double

    public init(inputSeconds: Double, outputSeconds: Double, ioBufferSeconds: Double) {
        self.inputSeconds = inputSeconds
        self.outputSeconds = outputSeconds
        self.ioBufferSeconds = ioBufferSeconds
    }

    /// How much later the recorded voice is than the backing track heard: input + output + IO buffer.
    public var roundTripSeconds: Double { inputSeconds + outputSeconds + ioBufferSeconds }
}

public enum AudioDeviceError: Error, Equatable {
    /// The input is no longer connected.
    case inputUnavailable
}

public enum AudioSessionEvent: Equatable, Sendable {
    /// Another app or the system (a call, an alarm) took the audio; playback must stop.
    case interruptionBegan
    case interruptionEnded
    /// The output in use went away (headphones unplugged, Bluetooth disconnected); playback pauses rather than
    /// continue on the speaker.
    case outputDeviceRemoved
    /// The input in use went away; recording pauses and never switches to the built-in mic (SPEC § 13.7).
    case inputDeviceRemoved
    /// An input was connected or removed: lists of inputs refresh.
    case availableInputsChanged
}
