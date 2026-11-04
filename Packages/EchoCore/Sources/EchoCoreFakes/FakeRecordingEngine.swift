import EchoCore
import Foundation
import Observation

/// Records nothing: moves through the states like the real engine, reports `peaks` and returns a take of
/// `takeDuration` seconds in the started folder, with a marker per interruption at `elapsedSeconds`.
/// `prepareError`/`startError`/`resumeError` make those calls throw; `end(_:)` acts like the engine ending a take by
/// itself (low storage, write failure).
@MainActor
@Observable
public final class FakeRecordingEngine: RecordingEngine {
    public private(set) var state: RecordingState = .idle
    public private(set) var inputChannelCount = 0
    public var elapsedSeconds: Double = 0
    public var continuesAfterRouteChange: (@MainActor () -> Bool)?
    public private(set) var suppression = SuppressionState.off
    /// High needs 44.1 kHz; set false to act like a Bluetooth headset.
    public var supportsHigh = true
    /// Channels the input offers once prepared.
    public var inputChannels: Int
    public var peaks: [Float]
    public var prepareError: RecordingError?
    public var startError: RecordingError?
    public var resumeError: RecordingError?
    public var takeDuration: Double = 1
    public private(set) var configuration: RecordingConfiguration?
    public private(set) var takeFolder: TakeFolder?
    public private(set) var finishedTakes = 0
    public private(set) var markers: [RecordingMetadata.Marker] = []

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

    public private(set) var inputGainDB: Double = 0
    public private(set) var monitorVolume: Double = 0
    public private(set) var autoTune = AutoTuneSettings()

    public func setAutoTune(_ settings: AutoTuneSettings) {
        autoTune = settings
    }

    public private(set) var backingTrack: BackingTrackInfo?
    public private(set) var backingTrackStart: Double = 0
    public private(set) var backingTrackVolume: Double = 0.8
    public private(set) var isPreviewingBackingTrack = false
    /// The duration `loadBackingTrack` reports.
    public var backingTrackDuration: Double = 180
    public var backingTrackError: RecordingError?

    public func loadBackingTrack(_ url: URL) throws {
        guard takeFolder == nil else { throw RecordingError.takeInProgress }
        if let backingTrackError { throw backingTrackError }
        backingTrack = BackingTrackInfo(url: url, duration: backingTrackDuration)
        backingTrackStart = 0
    }

    public func removeBackingTrack() {
        guard takeFolder == nil else { return }
        backingTrack = nil
        isPreviewingBackingTrack = false
    }

    public func setBackingTrackStart(_ seconds: Double) {
        guard takeFolder == nil, let backingTrack else { return }
        backingTrackStart = min(max(0, seconds), backingTrack.duration)
    }

    public func setBackingTrackVolume(_ volume: Double) {
        backingTrackVolume = min(1, max(0, volume))
    }

    public func previewBackingTrack(_ isPlaying: Bool) {
        isPreviewingBackingTrack = isPlaying && backingTrack != nil && takeFolder == nil
    }

    public func setMonitorVolume(_ volume: Double) {
        monitorVolume = min(1, max(0, volume))
    }

    public func setInputGain(_ db: Double) {
        inputGainDB = min(24, max(-24, db))
    }

    public func setSuppression(_ level: SuppressionLevel) {
        let effective: SuppressionLevel = level == .high && !supportsHigh ? .standard : level
        suppression = SuppressionState(
            level: level, effective: effective, usesVoiceProcessing: effective == .standard && inputChannels == 1
        )
    }

    public func takePeakLevels() -> [Float] {
        state == .idle ? [] : peaks
    }

    public func startTake(in folder: TakeFolder) throws {
        guard state == .ready else { throw RecordingError.noTake }
        if let startError { throw startError }
        takeFolder = folder
        markers = []
        state = .recording
    }

    public func pause() {
        if state == .recording { state = .paused }
    }

    public func interrupt(_ kind: RecordingMetadata.Marker.Kind) {
        switch state {
        case .recording, .paused:
            markers.append(RecordingMetadata.Marker(time: elapsedSeconds, kind: kind))
            state = .pausedByInterruption(kind)
        case .ready:
            state = .idle
            inputChannelCount = 0
        default:
            break
        }
    }

    public func resume() throws {
        switch state {
        case .paused:
            break
        case .pausedByInterruption:
            if let resumeError { throw resumeError }
        default:
            throw RecordingError.noTake
        }
        state = .recording
    }

    public func finishTake() async throws -> RecordedTake {
        switch state {
        case .recording, .paused, .pausedByInterruption, .ended:
            guard let takeFolder, let configuration else { throw RecordingError.noTake }
            self.takeFolder = nil
            finishedTakes += 1
            state = .ready
            elapsedSeconds = 0
            var take = RecordedTake(
                folder: takeFolder, duration: takeDuration, mixdownChannelCount: configuration.mixdownChannelCount,
                channelFileCount: configuration.writesChannelFiles ? configuration.channels.count : 0, droppedFrames: 0,
                markers: markers
            )
            take.backingTrackStart = backingTrack == nil ? nil : backingTrackStart
            return take
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
        switch state {
        case .recording, .paused, .pausedByInterruption: state = .ended(reason)
        default: break
        }
    }
}
