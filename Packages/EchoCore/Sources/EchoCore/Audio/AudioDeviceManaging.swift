/// Audio session, inputs, channels, latency and route changes (SPEC § 4.3, § 13.2). The editor needs playback only;
/// recording adds inputs and routes in F10.
@MainActor
public protocol AudioDeviceManaging: AnyObject {
    /// Configures and activates the session for editor playback (plays with the silent switch on).
    func activateForPlayback() throws
    /// Session changes playback must react to. Each call returns a new stream; it ends when its consumer stops.
    func sessionEvents() -> AsyncStream<AudioSessionEvent>
}

public enum AudioSessionEvent: Equatable, Sendable {
    /// Another app or the system (a call, an alarm) took the audio; playback must stop.
    case interruptionBegan
    case interruptionEnded
    /// The output in use went away (headphones unplugged, Bluetooth disconnected); playback pauses rather than
    /// continue on the speaker.
    case outputDeviceRemoved
}
