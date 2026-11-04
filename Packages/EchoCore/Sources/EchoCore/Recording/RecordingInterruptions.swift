import Observation

/// Drives a take through audio session events (SPEC § 13.7): a call or another app pauses it as an interruption, a lost
/// input as a route change, each flushed and marked by the engine. Resume becomes possible once the call is over and
/// the recorded input is available again, and re-selects that input first; nothing resumes by itself. A route change
/// that keeps the recorded input continues in the engine, which asks `isRecordedInputCurrent`.
@MainActor
@Observable
public final class RecordingInterruptions {
    private struct RecordedInput {
        let id: String
        let builtInMode: BuiltInMicMode
    }

    @ObservationIgnored private let devices: any AudioDeviceManaging
    @ObservationIgnored private let engine: any RecordingEngine
    private var input: RecordedInput?
    private var isCallActive = false
    private var availableInputIDs: Set<String> = []

    public init(devices: any AudioDeviceManaging, engine: any RecordingEngine) {
        self.devices = devices
        self.engine = engine
        engine.continuesAfterRouteChange = { [weak self] in self?.isRecordedInputCurrent ?? false }
    }

    /// Whether Resume can be offered: an interruption paused the take, no call is going on and the recorded input is
    /// available.
    public var canResume: Bool {
        guard case .pausedByInterruption = engine.state, !isCallActive, let input else { return false }
        return availableInputIDs.contains(input.id)
    }

    /// The input the take records, as chosen in the device sheet. Call before the take starts.
    public func track(inputID: String, builtInMode: BuiltInMicMode) {
        input = RecordedInput(id: inputID, builtInMode: builtInMode)
        refreshInputs()
    }

    /// Follows the session's events until the calling task is cancelled.
    public func run() async {
        for await event in devices.sessionEvents() {
            handle(event)
        }
    }

    func handle(_ event: AudioSessionEvent) {
        switch event {
        case .interruptionBegan:
            isCallActive = true
            engine.interrupt(.interruption)
        case .interruptionEnded:
            isCallActive = false
        case .inputDeviceRemoved:
            engine.interrupt(.routeChange)
        case .availableInputsChanged, .outputDeviceRemoved:
            break
        }
        refreshInputs()
    }

    /// Activates the session again, re-selects the recorded input and continues the take. Throws `.engineUnavailable`
    /// while the session can't be activated (the call isn't over), `.inputChanged` when the input is gone.
    public func resume() throws {
        guard let input else { throw RecordingError.noTake }
        do {
            try devices.activateForRecording()
        } catch {
            throw RecordingError.engineUnavailable
        }
        do {
            try devices.selectInput(id: input.id, builtInMode: input.builtInMode)
        } catch {
            throw RecordingError.inputChanged
        }
        try engine.resume()
    }

    /// The session still records from the input the take was started on (iOS falls back to the built-in mic when a
    /// headset goes away; the take must never continue on it).
    var isRecordedInputCurrent: Bool {
        guard let input else { return false }
        return devices.currentInputID == input.id
    }

    private func refreshInputs() {
        availableInputIDs = Set(devices.availableInputs().map(\.id))
    }
}
