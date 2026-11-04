import AVFoundation
import EchoAudioUnits
import Observation

/// `AVAudioEngine` capture (SPEC § 13.2, § 13.3): input node → capture unit → main mixer, which stays muted until
/// monitoring arrives (F11). The capture unit meters every input channel and, during a take, queues the selected
/// channels and the processed mixdown in a lock-free ring; a `TakeWriter` drains it every 50 ms into the take files,
/// converting to 48 kHz when the input runs at another rate, and ends the take by itself when free space runs low.
///
/// The configuration is locked while a take is open. Interruptions and route changes are F10.T03.
@MainActor
@Observable
public final class AVRecordingEngine: RecordingEngine {
    public private(set) var state: RecordingState = .idle
    public private(set) var inputChannelCount = 0

    /// Seconds of input the ring holds while the writer is late (an I/O stall).
    static let ringSeconds = 8.0

    /// Internal for tests that render offline.
    @ObservationIgnored let engine = AVAudioEngine()
    @ObservationIgnored private let captureNode: AVAudioUnitEffect
    @ObservationIgnored private let capture: CaptureCore
    @ObservationIgnored private let storage: any StorageEstimating
    @ObservationIgnored private let policy: RecordingStoragePolicy
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let drainInterval: Duration
    @ObservationIgnored private let storageCheckInterval: Duration
    /// Offline only: the format the input node's manual rendering block supplies.
    @ObservationIgnored private let manualInputFormat: AVAudioFormat?
    @ObservationIgnored private var configuration: RecordingConfiguration?
    @ObservationIgnored private var take: OpenTake?
    /// A take the engine ended by itself, until `finishTake` collects it.
    @ObservationIgnored private var endedTake: RecordedTake?

    private struct OpenTake {
        let writer: TakeWriter
        /// `capture.capturedFrames` when the take started.
        let capturedAtStart: Int64
        /// Drains the ring until cancelled or the take must end.
        let loop: Task<Void, Never>
    }

    public convenience init(storage: any StorageEstimating, policy: RecordingStoragePolicy = .standard) {
        self.init(
            storage: storage, policy: policy, clock: ContinuousClock(), drainInterval: .milliseconds(50),
            storageCheckInterval: .seconds(5), manualInputFormat: nil
        )
    }

    /// `manualInputFormat` set: renders offline for tests (`engine.renderOffline`), the input supplied through the input
    /// node's manual rendering block in that format.
    init(
        storage: any StorageEstimating, policy: RecordingStoragePolicy, clock: any Clock<Duration>, drainInterval: Duration,
        storageCheckInterval: Duration, manualInputFormat: AVAudioFormat?
    ) {
        EchoAudioUnits.register()
        captureNode = AVAudioUnitEffect(audioComponentDescription: RecordingCaptureAudioUnit.componentDescription)
        capture = (captureNode.auAudioUnit as! RecordingCaptureAudioUnit).core
        self.storage = storage
        self.policy = policy
        self.clock = clock
        self.drainInterval = drainInterval
        self.storageCheckInterval = storageCheckInterval
        self.manualInputFormat = manualInputFormat
        engine.attach(captureNode)
    }

    isolated deinit {
        // Never leave a take open: close its files with what was captured.
        if let take {
            Task {
                take.loop.cancel()
                await take.loop.value
                _ = await take.writer.finish()
            }
        }
    }

    private var captureUnit: RecordingCaptureAudioUnit { captureNode.auAudioUnit as! RecordingCaptureAudioUnit }

    private var inputFormat: AVAudioFormat { manualInputFormat ?? engine.inputNode.outputFormat(forBus: 0) }

    public var elapsedSeconds: Double {
        if let endedTake { return endedTake.duration }
        guard let take, capture.sampleRate > 0 else { return 0 }
        return Double(capture.capturedFrames - take.capturedAtStart) / capture.sampleRate
    }

    public func prepare(_ configuration: RecordingConfiguration) throws {
        guard take == nil, endedTake == nil, state != .finishing else { throw RecordingError.takeInProgress }
        engine.stop()
        state = .idle
        inputChannelCount = 0
        let format = inputFormat
        guard format.sampleRate > 0, format.channelCount > 0, Int(format.channelCount) <= CaptureCore.maximumInputChannels,
              let monitorFormat = AVAudioFormat(
                  standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(configuration.mixdownChannelCount)
              ) else {
            throw RecordingError.engineUnavailable
        }
        guard configuration.isValid(forInputChannelCount: Int(format.channelCount)) else { throw RecordingError.channelsUnavailable }
        do {
            try captureUnit.configure(
                sampleRate: format.sampleRate, inputChannelCount: Int(format.channelCount), channels: configuration.channels,
                mixdownChannelCount: configuration.mixdownChannelCount, ringFrames: Int(Self.ringSeconds * format.sampleRate)
            )
        } catch {
            throw RecordingError.channelsUnavailable
        }
        engine.disconnectNodeOutput(engine.inputNode)
        engine.disconnectNodeOutput(captureNode)
        engine.connect(engine.inputNode, to: captureNode, format: format)
        engine.connect(captureNode, to: engine.mainMixerNode, format: monitorFormat)
        // Monitoring through headphones is F11.T03; until then nothing is heard.
        engine.mainMixerNode.outputVolume = 0
        do {
            engine.prepare()
            try engine.start()
        } catch {
            throw RecordingError.engineUnavailable
        }
        self.configuration = configuration
        inputChannelCount = Int(format.channelCount)
        state = .ready
    }

    public func takePeakLevels() -> [Float] {
        state == .idle ? [] : capture.takePeaks()
    }

    public func startTake(in folder: TakeFolder) throws {
        guard state == .ready, let configuration else { throw RecordingError.noTake }
        let available = (try? storage.availableBytes()) ?? .max
        guard available >= policy.minimumToStart else { throw RecordingError.notEnoughSpace(availableBytes: available) }
        let writer: TakeWriter
        do {
            try FileManager().createDirectory(at: folder.url, withIntermediateDirectories: true)
            // Not capturing: anything left in the ring belongs to no take.
            capture.discard()
            writer = try TakeWriter(core: capture, folder: folder, configuration: configuration)
        } catch {
            throw RecordingError.cantCreateFiles
        }
        capture.setTakeOpen(true)
        let capturedAtStart = capture.capturedFrames
        capture.setCapturing(true)
        // High priority whoever starts the take: at a lower one, a busy device delays the drain's timer by seconds.
        let loop = Task(priority: .high) { [weak self, clock, storage, drainInterval, storageCheckInterval, stopBelow = policy.stopBelow] in
            let reason = await writer.run(
                interval: drainInterval, storageCheckInterval: storageCheckInterval, clock: clock, storage: storage, stopBelow: stopBelow
            )
            guard let reason else { return }
            await self?.endTake(reason)
        }
        take = OpenTake(writer: writer, capturedAtStart: capturedAtStart, loop: loop)
        state = .recording
    }

    public func pause() {
        guard state == .recording, let take else { return }
        capture.setCapturing(false)
        state = .paused
        Task { [writer = take.writer] in
            await waitForLastCapturingCycle()
            try? await writer.flush()
        }
    }

    public func resume() {
        guard state == .paused else { return }
        capture.setCapturing(true)
        state = .recording
    }

    public func finishTake() async throws -> RecordedTake {
        switch state {
        case .ended:
            guard let endedTake else { throw RecordingError.noTake }
            self.endedTake = nil
            state = engine.isRunning ? .ready : .idle
            return endedTake
        case .recording, .paused:
            guard let take else { throw RecordingError.noTake }
            state = .finishing
            let recorded = await close(take, isLoopRunning: true)
            state = engine.isRunning ? .ready : .idle
            return recorded
        default:
            throw RecordingError.noTake
        }
    }

    public func shutDown() {
        guard take == nil, endedTake == nil, state != .finishing else { return }
        engine.stop()
        state = .idle
        inputChannelCount = 0
    }

    /// The writer's loop found the take must end (low storage, write failure).
    private func endTake(_ reason: TakeEndReason) async {
        guard state == .recording || state == .paused, let take else { return }
        state = .finishing
        endedTake = await close(take, isLoopRunning: false)
        state = .ended(reason)
    }

    private func close(_ take: OpenTake, isLoopRunning: Bool) async -> RecordedTake {
        capture.setCapturing(false)
        await waitForLastCapturingCycle()
        if isLoopRunning {
            take.loop.cancel()
            await take.loop.value
        }
        let recorded = await take.writer.finish()
        capture.setTakeOpen(false)
        self.take = nil
        return recorded
    }

    /// After `setCapturing(false)`, a render cycle already running may still queue its audio: waits until a full
    /// cycle has started since (two finished cycles), so the writer sees it. Up to 250 ms, in case the engine stopped.
    private func waitForLastCapturingCycle() async {
        guard manualInputFormat == nil, engine.isRunning else { return }
        let start = capture.renderCycles
        var waited = 0
        while capture.renderCycles < start + 2, waited < 50 {
            try? await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
    }
}

extension AVRecordingEngine {
    /// Offline (tests): an engine that renders with `engine.renderOffline`, its input supplied in `inputFormat` through
    /// `engine.inputNode.setManualRenderingInputPVMBlock`.
    static func offline(
        inputFormat: AVAudioFormat, storage: any StorageEstimating, policy: RecordingStoragePolicy = .standard,
        clock: any Clock<Duration> = ContinuousClock(), drainInterval: Duration = .milliseconds(50),
        storageCheckInterval: Duration = .seconds(5)
    ) throws -> AVRecordingEngine {
        let recorder = AVRecordingEngine(
            storage: storage, policy: policy, clock: clock, drainInterval: drainInterval,
            storageCheckInterval: storageCheckInterval, manualInputFormat: inputFormat
        )
        let output = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate, channels: 2)!
        try recorder.engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 4_096)
        return recorder
    }
}
