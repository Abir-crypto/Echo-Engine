import EchoCore

/// Counts activations and keeps a list of inputs; throws `error` when set. `send` delivers a session event to every
/// open stream.
@MainActor
public final class FakeAudioDeviceManager: AudioDeviceManaging {
    public private(set) var playbackActivations = 0
    public private(set) var recordingActivations = 0
    public var inputs: [AudioInput]
    public private(set) var selectedInput: AudioInput?
    public private(set) var builtInMode: BuiltInMicMode?
    public var latency = AudioLatency(inputSeconds: 0.004, outputSeconds: 0.006, ioBufferSeconds: 0.005)
    public var selectedInputChannelCount: Int { selectedInput?.channelCount ?? 0 }
    /// The selected input; set it to nil or another id to act like iOS changing the route.
    public var currentInputID: String?
    public var outputKind = AudioOutputKind.speaker
    public var error: (any Error)?
    public var microphoneAccess = true
    public private(set) var microphoneRequests = 0
    private var continuations: [AsyncStream<AudioSessionEvent>.Continuation] = []

    public init(inputs: [AudioInput] = []) {
        self.inputs = inputs
    }

    public func activateForPlayback() throws {
        if let error { throw error }
        playbackActivations += 1
    }

    public func activateForRecording() throws {
        if let error { throw error }
        recordingActivations += 1
    }

    public func availableInputs() -> [AudioInput] { inputs }

    public func requestMicrophoneAccess() async -> Bool {
        microphoneRequests += 1
        return microphoneAccess
    }

    public func selectInput(id: String, builtInMode: BuiltInMicMode) throws {
        guard let input = inputs.first(where: { $0.id == id }) else { throw AudioDeviceError.inputUnavailable }
        selectedInput = input
        currentInputID = input.id
        self.builtInMode = builtInMode
    }

    public func sessionEvents() -> AsyncStream<AudioSessionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioSessionEvent.self)
        continuations.append(continuation)
        return stream
    }

    public func send(_ event: AudioSessionEvent) {
        continuations.forEach { $0.yield(event) }
    }
}
