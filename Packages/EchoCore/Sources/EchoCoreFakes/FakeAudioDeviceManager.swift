import EchoCore

/// Counts activations; throws `error` when set.
@MainActor
public final class FakeAudioDeviceManager: AudioDeviceManaging {
    public private(set) var playbackActivations = 0
    public var error: (any Error)?

    public init() {}

    public func activateForPlayback() throws {
        if let error { throw error }
        playbackActivations += 1
    }
}
