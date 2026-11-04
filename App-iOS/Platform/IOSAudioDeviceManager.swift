import AVFoundation
import EchoCore

/// Wraps the shared `AVAudioSession` (SPEC § 4.1, § 13.2): playback for the editor; inputs, channels and latency for
/// recording.
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

    func activateForRecording() throws {
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setPreferredSampleRate(48_000)
        try session.setActive(true)
    }

    func availableInputs() -> [AudioInput] {
        (session.availableInputs ?? []).map { port in
            AudioInput(
                id: port.uid,
                name: port.portName,
                kind: Self.kind(of: port),
                channelCount: max(port.channels?.count ?? 1, 1),
                supportsStereo: Self.stereoSource(of: port) != nil
            )
        }
    }

    func selectInput(id: String, builtInMode: BuiltInMicMode) throws {
        guard let port = session.availableInputs?.first(where: { $0.uid == id }) else { throw AudioDeviceError.inputUnavailable }
        try session.setPreferredInput(port)
        guard port.portType == .builtInMic else {
            // iOS may deliver only the first channel(s) of an interface; ask for all, so any of them can be recorded.
            try? session.setPreferredInputNumberOfChannels(session.maximumInputNumberOfChannels)
            return
        }
        if builtInMode == .stereo, let source = Self.stereoSource(of: port) {
            try source.setPreferredPolarPattern(.stereo)
            try port.setPreferredDataSource(source)
            try session.setPreferredInputNumberOfChannels(2)
        } else {
            try session.setPreferredInputNumberOfChannels(1)
        }
    }

    var latency: AudioLatency {
        AudioLatency(inputSeconds: session.inputLatency, outputSeconds: session.outputLatency, ioBufferSeconds: session.ioBufferDuration)
    }

    var selectedInputChannelCount: Int {
        session.maximumInputNumberOfChannels
    }

    var currentInputID: String? {
        session.currentRoute.inputs.first?.uid
    }

    private static func kind(of port: AVAudioSessionPortDescription) -> AudioInput.Kind {
        switch port.portType {
        case .builtInMic: .builtInMic
        case .headsetMic: .headsetMic
        case .usbAudio: .usb
        case .bluetoothHFP, .bluetoothLE: .bluetooth
        default: .other
        }
    }

    /// The built-in mic's data source that records stereo, where the device has one.
    private static func stereoSource(of port: AVAudioSessionPortDescription) -> AVAudioSessionDataSourceDescription? {
        guard port.portType == .builtInMic else { return nil }
        return port.dataSources?.first { $0.supportedPolarPatterns?.contains(.stereo) == true }
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
            notifications.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [session] note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
                guard reason == .oldDeviceUnavailable || reason == .newDeviceAvailable else { return }
                continuation.yield(.availableInputsChanged)
                guard reason == .oldDeviceUnavailable else { return }
                let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
                let current = Set(session.currentRoute.inputs.map(\.uid))
                // An input that was in use is gone: recording must not carry on with another one (SPEC § 13.7).
                if previous?.inputs.contains(where: { !current.contains($0.uid) }) == true {
                    continuation.yield(.inputDeviceRemoved)
                }
                continuation.yield(.outputDeviceRemoved)
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
