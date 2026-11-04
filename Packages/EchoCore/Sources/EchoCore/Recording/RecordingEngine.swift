import Foundation
import Observation

/// Live capture into take files with level meters (SPEC § 4.3, § 13): the selected channels of the session's input,
/// written continuously as `raw.caf`, `processed.caf` and, for several summed channels, `ch<N>.caf`.
///
/// `prepare` starts metering; `startTake` opens the files and records; `pause`/`resume` hold the take; `finishTake`
/// writes out everything captured and closes it. Calls, other apps and lost inputs interrupt the take
/// (`.pausedByInterruption`) until the person resumes it (SPEC § 13.7). The engine ends a take by itself when space
/// runs out or a write fails (`.ended`); `finishTake` then hands it over.
@MainActor
public protocol RecordingEngine: AnyObject, Observable {
    var state: RecordingState { get }
    /// Channels of the input being metered; 0 before `prepare`.
    var inputChannelCount: Int { get }
    /// Seconds recorded in the open take, pauses excluded; 0 without one. Not observed: read it on every frame.
    var elapsedSeconds: Double { get }
    /// The open take's interruption and route-change markers so far (they end up in `RecordedTake.markers`).
    var markers: [RecordingMetadata.Marker] { get }
    /// The noise reduction running (SPEC § 13.4).
    var suppression: SuppressionState { get }
    /// Chooses the noise reduction; kept across `prepare` and applied at once, during a take too (ramped; a change to or
    /// from Standard with voice processing restarts the audio briefly and marks the take). Falls back as `suppression`
    /// tells.
    func setSuppression(_ level: SuppressionLevel)
    /// The input gain before live processing (SPEC § 13.4), −24…+24 dB; ramped, any time. The meters show it.
    var inputGainDB: Double { get }
    func setInputGain(_ db: Double)
    /// How loud the processed signal plays back to the person (SPEC § 13.4), 0…1; 0 is silent. Kept across `prepare`.
    var monitorVolume: Double { get }
    func setMonitorVolume(_ volume: Double)
    /// Live auto-tune (SPEC § 13.5), any time; switching it on or off fades briefly. Kept across `prepare`.
    var autoTune: AutoTuneSettings { get }
    func setAutoTune(_ settings: AutoTuneSettings)
    /// Asked when the system stops the engine for a route change: true when the recorded input is still the session's
    /// current one, so recording continues on it right away with a marker at the gap (user decision, SPEC § 13.7).
    /// Otherwise (or when nil) the take pauses like an interruption.
    var continuesAfterRouteChange: (@MainActor () -> Bool)? { get set }

    /// Starts the engine on the session's current input (already selected and activated through `AudioDeviceManaging`)
    /// and meters it; replaces the previous configuration. Throws `.channelsUnavailable` when the input lacks the
    /// channels, `.engineUnavailable` when there is no input, `.takeInProgress` while a take is open.
    func prepare(_ configuration: RecordingConfiguration) throws
    /// The highest level of each input channel since the previous call (1 = full scale, clipping at or above), by input
    /// channel index. Poll it for the meters.
    func takePeakLevels() -> [Float]
    /// Creates the take's files in `folder` and starts recording. Throws `.notEnoughSpace` below the storage policy's
    /// minimum (SPEC § 15).
    func startTake(in folder: TakeFolder) throws
    /// Stops adding audio to the take and writes out what was captured; meters keep running.
    func pause()
    /// A call, another app or a lost input stopped the audio (SPEC § 13.7): stops adding audio, writes everything
    /// captured to disk and marks the take at this point. Only `resume()` continues it, never the engine itself. Without
    /// a take the engine stops: `prepare` again.
    func interrupt(_ kind: RecordingMetadata.Marker.Kind)
    /// Continues the same take after `pause` or an interruption, restarting the engine if it stopped. Throws
    /// `.inputChanged` when the input no longer matches the take, `.engineUnavailable` when it can't start yet (the call
    /// isn't over). The caller checks the chosen input is back first: the engine records whatever the session routes.
    func resume() throws
    /// Writes out everything captured, closes the files and returns the take; meters keep running. After the engine
    /// ended the take by itself (`.ended`), returns that take.
    func finishTake() async throws -> RecordedTake
    /// Stops the engine and the meters. Does nothing while a take is open: finish it first.
    func shutDown()
}

public enum RecordingState: Equatable, Sendable {
    /// The engine is stopped.
    case idle
    /// Meters run; no take is open.
    case ready
    case recording
    case paused
    /// A call, another app or a lost input stopped the take; waits for `resume()` (SPEC § 13.7).
    case pausedByInterruption(RecordingMetadata.Marker.Kind)
    /// Writing out and closing the take.
    case finishing
    /// The engine ended the take by itself; `finishTake()` returns it.
    case ended(TakeEndReason)
}

public enum TakeEndReason: Equatable, Sendable {
    /// Free space dropped below the storage policy's stop level (SPEC § 15).
    case lowStorage
    /// A file couldn't be written; everything written before is kept.
    case writeFailed
}

public enum RecordingError: Error, Equatable {
    /// Less free space than a recording needs to start (SPEC § 15), with the bytes available for the message.
    case notEnoughSpace(availableBytes: Int64)
    /// The configuration asks for channels the input doesn't have.
    case channelsUnavailable
    /// No input to record from, or the audio engine couldn't start.
    case engineUnavailable
    /// After an interruption, the input's channels or rate differ from the open take's.
    case inputChanged
    /// The take's files couldn't be created.
    case cantCreateFiles
    /// `prepare` while a take is open.
    case takeInProgress
    /// No take to start, pause or finish in the current state.
    case noTake
    /// The take holds no audio (the app was killed as it started).
    case emptyTake
    /// The recorded project couldn't be made from the take.
    case cantCreateProject
}

/// A finished take's files (SPEC § 13.3): `raw.caf` and `processed.caf`, plus `ch1.caf`…`ch<N>.caf` when several
/// channels were summed. All are 48 kHz 32-bit float CAF of the same length.
public struct RecordedTake: Equatable, Sendable {
    public let folder: TakeFolder
    /// Seconds of audio in the mixdown files.
    public let duration: Double
    public let mixdownChannelCount: Int
    /// Number of `ch<N>.caf` files; 0 when they weren't written.
    public let channelFileCount: Int
    /// Input frames lost because writing fell behind; silence took their place, so the take kept its length.
    public let droppedFrames: Int64
    /// Where interruptions and lost inputs paused the take (SPEC § 13.7), for `RecordingMetadata.markers`.
    public var markers: [RecordingMetadata.Marker]

    public init(
        folder: TakeFolder, duration: Double, mixdownChannelCount: Int, channelFileCount: Int, droppedFrames: Int64,
        markers: [RecordingMetadata.Marker] = []
    ) {
        self.folder = folder
        self.duration = duration
        self.mixdownChannelCount = mixdownChannelCount
        self.channelFileCount = channelFileCount
        self.droppedFrames = droppedFrames
        self.markers = markers
    }

    public var channelFiles: [URL] { (0..<channelFileCount).map { folder.channel($0 + 1) } }
}

/// Free space a recording needs (user decision, SPEC § 15): it doesn't start below `minimumToStart`, and a take ends
/// by itself, saved, when free space drops below `stopBelow`.
public struct RecordingStoragePolicy: Equatable, Sendable {
    public var minimumToStart: Int64
    public var stopBelow: Int64

    public init(minimumToStart: Int64, stopBelow: Int64) {
        self.minimumToStart = minimumToStart
        self.stopBelow = stopBelow
    }

    public static let standard = RecordingStoragePolicy(minimumToStart: 500_000_000, stopBelow: 200_000_000)
}
