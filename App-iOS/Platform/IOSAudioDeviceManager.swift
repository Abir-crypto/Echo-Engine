import AVFoundation
import EchoCore

/// Wraps the shared `AVAudioSession` (SPEC § 4.1, § 13.2). Recording adds inputs and routes in F10.
@MainActor
final class IOSAudioDeviceManager: AudioDeviceManaging {
    private let session: AVAudioSession
    private let notifications: NotificationCenter

    init(session: AVAudioSession = .sharedInstance(), notifications: NotificationCenter = .default) {
        self.session = session
        self.notifications = notifications
    }

    func activateForPlayback() throws {
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    func sessionEvents() -> AsyncStream<AudioSessionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioSessionEvent.self)
        let observers = NotificationObservers(center: notifications, tokens: [
            notifications.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                switch type {
                case .began: continuation.yield(.interruptionBegan)
                case .ended: continuation.yield(.interruptionEnded)
                default: break
                }
            },
            notifications.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
                if reason == .oldDeviceUnavailable { continuation.yield(.outputDeviceRemoved) }
            },
        ])
        continuation.onTermination = { _ in observers.remove() }
        return stream
    }
}

/// Notification observer tokens, removed together when a stream ends.
private struct NotificationObservers: @unchecked Sendable {
    let center: NotificationCenter
    let tokens: [any NSObjectProtocol]

    func remove() {
        tokens.forEach(center.removeObserver)
    }
}
