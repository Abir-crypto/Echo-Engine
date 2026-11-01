/// Audio session, inputs, channels, latency and route changes (SPEC § 4.3, § 13.2). The editor needs playback only;
/// recording adds inputs and routes in F10.
@MainActor
public protocol AudioDeviceManaging: AnyObject {
    /// Configures and activates the session for editor playback (plays with the silent switch on).
    func activateForPlayback() throws
}
