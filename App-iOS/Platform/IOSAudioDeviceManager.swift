import AVFoundation
import EchoCore

/// Wraps the shared `AVAudioSession` (SPEC § 4.1, § 13.2). Recording adds inputs and routes in F10.
@MainActor
final class IOSAudioDeviceManager: AudioDeviceManaging {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    func activateForPlayback() throws {
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }
}
