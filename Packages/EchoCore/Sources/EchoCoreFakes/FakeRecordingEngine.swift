import EchoCore
import Observation

/// Records nothing: moves through the states like the real engine, reports `peaks` and returns a take of
/// `takeDuration` seconds in the started folder. `prepareError`/`startError` make those calls throw; `end(_:)` acts
/// like the engine ending a take by itself (low storage, write failure).
@MainActor
@Observable
public final class FakeRecordingEngine: RecordingEngine {
    public private(set) var state: RecordingState = .idle
    public private(set) var inputChannelCount = 0
    public var elapsedSeconds: Double = 0
    /// Channels the input offers once prepared.
    public var inputChannels: Int
    public var peaks: [Float]
    public var prepareError: RecordingError?
    public var startError: RecordingError?
    public var takeDuration: Double = 1
    public private(set) var configuration: RecordingConfiguration?
    public private(set) var takeFolder: TakeFolder?
    public private(set) var finishedTakes = 0

    public init(inputChannels: Int = 1, peaks: [Float] = []) {
        self.inputChannels = inputChannels
        self.peaks = peaks
    }

    public func prepare(_ configuration: RecordingConfiguration) throws {
        guard takeFolder == nil, state != .finishing else { throw RecordingError.takeInProgress }
        if let prepareError { throw prepareError }
        guard configuration.isValid(forInputChannelCount: inputChannels) else { throw RecordingError.channelsUnavailable }
        self.configuration = configuration
        inputChannelCount = inputChannels
        state = .ready
    }

    public func takePeakLevels() -> [Float] {
        state == .idle ? [] : peaks
    }

    public func startTake(in folder: TakeFolder) throws {
        guard state == .ready else { throw RecordingError.noTake }
        if let startError { throw startError }
        takeFolder = folder
        state = .recording
    }

    public func pause() {
        if state == .recording { state = .paused }
    }

    public func resume() {
        if state == .paused { state = .recording }
    }

    public func finishTake() async throws -> RecordedTake {
        switch state {
        case .recording, .paused, .ended:
            guard let takeFolder, let configuration else { throw RecordingError.noTake }
            self.takeFolder = nil
            finishedTakes += 1
            state = .ready
            elapsedSeconds = 0
            return RecordedTake(
                folder: takeFolder, duration: takeDuration, mixdownChannelCount: configuration.mixdownChannelCount,
                channelFileCount: configuration.writesChannelFiles ? configuration.channels.count : 0, droppedFrames: 0
            )
        default:
            throw RecordingError.noTake
        }
    }

    public func shutDown() {
        guard takeFolder == nil else { return }
        state = .idle
        inputChannelCount = 0
    }

    /// The engine ends the open take by itself.
    public func end(_ reason: TakeEndReason) {
        guard state == .recording || state == .paused else { return }
        state = .ended(reason)
    }
}
