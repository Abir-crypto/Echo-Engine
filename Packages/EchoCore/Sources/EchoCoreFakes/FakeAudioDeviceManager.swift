import EchoCore

/// Counts activations; throws `error` when set. `send` delivers a session event to every open stream.
@MainActor
public final class FakeAudioDeviceManager: AudioDeviceManaging {
    public private(set) var playbackActivations = 0
    public var error: (any Error)?
    private var continuations: [AsyncStream<AudioSessionEvent>.Continuation] = []

    public init() {}

    public func activateForPlayback() throws {
        if let error { throw error }
        playbackActivations += 1
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
