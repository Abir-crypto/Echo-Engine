import AVFoundation
import EchoCoreFakes
import Foundation
import Testing
@testable import EchoCore

/// The real graph (input node → capture unit → main mixer), rendered offline with a synthetic input.
@MainActor
struct AVRecordingEngineTests {
    private let stereoInput = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    /// Channel 0 counts frames (so gaps show), channel 1 is a constant.
    private static let signal: @Sendable (Int, Int) -> Float = { channel, frame in
        channel == 0 ? Float(frame) * 1e-6 : 0.25
    }

    private func makeEngine(
        storage: any StorageEstimating = FakeStorageEstimator(),
        policy: RecordingStoragePolicy = .standard,
        drainInterval: Duration = .milliseconds(50),
        storageCheckInterval: Duration = .seconds(5),
        signal: @escaping @Sendable (Int, Int) -> Float = AVRecordingEngineTests.signal
    ) throws -> (AVRecordingEngine, SignalInput) {
        let engine = try AVRecordingEngine.offline(
            inputFormat: stereoInput, storage: storage, policy: policy,
            drainInterval: drainInterval, storageCheckInterval: storageCheckInterval
        )
        let input = SignalInput(format: stereoInput, signal: signal)
        _ = engine.engine.inputNode.setManualRenderingInputPCMFormat(stereoInput) { input.next($0) }
        return (engine, input)
    }

    private func render(_ engine: AVRecordingEngine, frames: Int) throws {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.engine.manualRenderingFormat, frameCapacity: 4_096)!
        var rendered = 0
        while rendered < frames {
            let count = AVAudioFrameCount(min(4_096, frames - rendered))
            let status = try engine.engine.renderOffline(count, to: buffer)
            try #require(status == .success)
            rendered += Int(count)
        }
    }

    @Test func recordsTheSelectedChannelsIntoTheTakeFiles() async throws {
        let (engine, _) = try makeEngine()
        try engine.prepare(.mono(channels: [0, 1]))
        #expect(engine.state == .ready)
        #expect(engine.inputChannelCount == 2)
        let folder = TakeFolder(url: try temporaryFolder().appending(path: "takes"))

        try engine.startTake(in: folder)
        #expect(engine.state == .recording)
        try render(engine, frames: 48_000)
        #expect(engine.elapsedSeconds == 1)
        let take = try await engine.finishTake()

        #expect(engine.state == .ready, "meters keep running")
        #expect(engine.elapsedSeconds == 0)
        #expect(take.duration == 1)
        #expect(take.channelFileCount == 2)
        let first = (0..<48_000).map { Self.signal(0, $0) }
        #expect(try readSamples(folder.channel(1)).channels == [first])
        #expect(try readSamples(folder.channel(2)).channels == [[Float](repeating: 0.25, count: 48_000)])
        #expect(try readSamples(folder.raw).channels == [first.map { $0 + 0.25 }])
        let processed = try readSamples(folder.processed).channels[0]
        #expect(processed.count == 48_000)
        #expect(processed.suffix(processedLatency48k).allSatisfy { $0 == 0 }, "the last moment was still in the live chain")
        #expect(engine.suppression == .off)
    }

    @Test func pausedAudioIsLeftOutOfTheTake() async throws {
        let (engine, _) = try makeEngine()
        try engine.prepare(.mono(channels: [0]))
        let folder = TakeFolder(url: try temporaryFolder())
        try engine.startTake(in: folder)
        try render(engine, frames: 24_000)
        engine.pause()
        #expect(engine.state == .paused)
        try render(engine, frames: 12_000)
        try engine.resume()
        try render(engine, frames: 12_000)
        let take = try await engine.finishTake()

        #expect(take.duration == 0.75, "0.5 s, then 0.25 s after resuming")
        let raw = try readSamples(folder.raw).channels[0]
        #expect(raw[23_999] == Self.signal(0, 23_999))
        #expect(raw[24_000] == Self.signal(0, 36_000), "continues where recording resumed")
    }

    @Test func metersEveryInputChannelWithoutATake() throws {
        let (engine, _) = try makeEngine { channel, frame in frame == 1_000 ? (channel == 0 ? -0.5 : 0.125) : 0 }
        #expect(engine.takePeakLevels().isEmpty, "nothing before prepare")
        try engine.prepare(.mono(channels: [1]))
        try render(engine, frames: 4_096)
        #expect(engine.takePeakLevels() == [0.5, 0.125])
        #expect(engine.takePeakLevels() == [0, 0])
    }

    @Test func refusesChannelsTheInputLacks() throws {
        let (engine, _) = try makeEngine()
        #expect(throws: RecordingError.channelsUnavailable) { try engine.prepare(.mono(channels: [2])) }
        #expect(engine.state == .idle)
        try engine.prepare(.builtInStereo)
        #expect(engine.state == .ready)
    }

    @Test func doesNotStartWithLittleSpaceLeft() throws {
        let (engine, _) = try makeEngine(storage: FakeStorageEstimator(available: 400_000_000))
        try engine.prepare(.mono(channels: [0]))
        let folder = TakeFolder(url: try temporaryFolder())
        #expect(throws: RecordingError.notEnoughSpace(availableBytes: 400_000_000)) { try engine.startTake(in: folder) }
        #expect(engine.state == .ready)
        #expect(try FileManager().contentsOfDirectory(atPath: folder.url.path()).isEmpty)
    }

    @Test func theConfigurationIsLockedDuringATake() async throws {
        let (engine, _) = try makeEngine()
        try engine.prepare(.mono(channels: [0]))
        try engine.startTake(in: TakeFolder(url: try temporaryFolder()))
        #expect(throws: RecordingError.takeInProgress) { try engine.prepare(.mono(channels: [1])) }
        engine.shutDown()
        #expect(engine.state == .recording, "shutting down waits for the take to finish")
        _ = try await engine.finishTake()
        engine.shutDown()
        #expect(engine.state == .idle)
        await #expect(throws: RecordingError.noTake) { try await engine.finishTake() }
    }

    @Test func endsAndSavesTheTakeWhenSpaceRunsLow() async throws {
        let storage = ChangingStorage(available: 1_000)
        let (engine, _) = try makeEngine(
            storage: storage, policy: RecordingStoragePolicy(minimumToStart: 500, stopBelow: 200),
            drainInterval: .milliseconds(1), storageCheckInterval: .milliseconds(1)
        )
        try engine.prepare(.mono(channels: [0]))
        let folder = TakeFolder(url: try temporaryFolder())
        try engine.startTake(in: folder)
        try render(engine, frames: 9_600)
        storage.set(100)

        let deadline = ContinuousClock.now + .seconds(5)
        while engine.state != .ended(.lowStorage), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(engine.state == .ended(.lowStorage))
        #expect(engine.elapsedSeconds == 0.2)
        try render(engine, frames: 4_800)   // no longer recorded

        let take = try await engine.finishTake()
        #expect(take.duration == 0.2)
        #expect(engine.state == .ready)
        #expect(try readSamples(folder.raw).channels[0].count == 9_600)
    }

    // MARK: Interruptions (SPEC § 13.7)

    @Test func anInterruptionPausesMarksTheTakeAndWaitsForResume() async throws {
        let (engine, _) = try makeEngine()
        try engine.prepare(.mono(channels: [0]))
        let folder = TakeFolder(url: try temporaryFolder())
        try engine.startTake(in: folder)
        try render(engine, frames: 24_000)
        engine.interrupt(.interruption)
        #expect(engine.state == .pausedByInterruption(.interruption))
        try render(engine, frames: 12_000)   // the call: not recorded
        #expect(engine.state == .pausedByInterruption(.interruption), "never resumes by itself")
        try engine.resume()
        #expect(engine.state == .recording)
        try render(engine, frames: 12_000)
        let take = try await engine.finishTake()

        #expect(take.duration == 0.75)
        #expect(take.markers == [RecordingMetadata.Marker(time: 0.5, kind: .interruption)])
        let raw = try readSamples(folder.raw).channels[0]
        #expect(raw[24_000] == Self.signal(0, 36_000), "the same take continues after the call")
    }

    @Test func everythingCapturedIsOnDiskWhenInterrupted() async throws {
        let (engine, _) = try makeEngine()
        try engine.prepare(.mono(channels: [0, 1]))
        let folder = TakeFolder(url: try temporaryFolder())
        try engine.startTake(in: folder)
        try render(engine, frames: 30_000)
        engine.interrupt(.routeChange)

        // The files are still open: readable as they are, as after a crash.
        let deadline = ContinuousClock.now + .seconds(5)
        var frames = 0
        while frames < 30_000, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            frames = try readSamples(folder.channel(2)).channels[0].count
        }
        #expect(frames == 30_000)
        #expect(try readSamples(folder.raw).channels[0].count == 30_000)
        _ = try await engine.finishTake()
    }

    @Test func aStoppedEngineIsAnInterruptionAndResumeRestartsIt() async throws {
        let (engine, _) = try makeEngine()
        try engine.prepare(.mono(channels: [0]))
        try engine.startTake(in: TakeFolder(url: try temporaryFolder()))
        try render(engine, frames: 4_800)
        engine.engine.stop()
        engine.handleConfigurationChange()
        #expect(engine.state == .pausedByInterruption(.routeChange))

        engine.interrupt(.interruption)
        #expect(engine.state == .pausedByInterruption(.interruption), "a call is the more specific cause")
        try engine.resume()
        #expect(engine.engine.isRunning)
        try render(engine, frames: 4_800)
        let take = try await engine.finishTake()
        #expect(take.duration == 0.2)
        #expect(take.markers == [RecordingMetadata.Marker(time: 0.1, kind: .interruption)])
    }

    @Test func aTakeCanBeFinishedWhileInterrupted() async throws {
        let (engine, _) = try makeEngine()
        try engine.prepare(.mono(channels: [0]))
        try engine.startTake(in: TakeFolder(url: try temporaryFolder()))
        try render(engine, frames: 9_600)
        engine.interrupt(.routeChange)
        let take = try await engine.finishTake()
        #expect(take.duration == 0.2)
        #expect(take.markers.map(\.kind) == [.routeChange])
        #expect(engine.state == .ready)
        #expect(throws: RecordingError.noTake) { try engine.resume() }
    }

    @Test func withoutATakeAnInterruptionStopsTheMeters() throws {
        let (engine, _) = try makeEngine()
        try engine.prepare(.mono(channels: [0]))
        engine.handleConfigurationChange()
        #expect(engine.state == .idle)
        #expect(engine.inputChannelCount == 0)
        #expect(engine.takePeakLevels().isEmpty)
        try engine.prepare(.mono(channels: [0]))
        #expect(engine.state == .ready)
    }

    @Test func aRouteChangeThatKeepsTheInputContinuesTheTake() async throws {
        let (engine, _) = try makeEngine()
        engine.continuesAfterRouteChange = { true }
        try engine.prepare(.mono(channels: [0]))
        try engine.startTake(in: TakeFolder(url: try temporaryFolder()))
        try render(engine, frames: 4_800)
        engine.engine.stop()   // headphones unplugged: the system stops the engine
        engine.handleConfigurationChange()

        #expect(engine.state == .recording)
        #expect(engine.engine.isRunning)
        try render(engine, frames: 4_800)
        let take = try await engine.finishTake()
        #expect(take.duration == 0.2)
        #expect(take.markers == [RecordingMetadata.Marker(time: 0.1, kind: .routeChange)])
    }

    @Test func aRouteChangeToAnotherInputPausesTheTake() async throws {
        let (engine, _) = try makeEngine()
        engine.continuesAfterRouteChange = { false }
        try engine.prepare(.mono(channels: [0]))
        try engine.startTake(in: TakeFolder(url: try temporaryFolder()))
        try render(engine, frames: 4_800)
        engine.engine.stop()
        engine.handleConfigurationChange()
        #expect(engine.state == .pausedByInterruption(.routeChange))
        _ = try await engine.finishTake()
    }

    @Test func aRouteChangeKeepsMeteringWhenTheInputStays() throws {
        let (engine, _) = try makeEngine()
        engine.continuesAfterRouteChange = { true }
        try engine.prepare(.mono(channels: [0]))
        engine.engine.stop()
        engine.handleConfigurationChange()
        #expect(engine.state == .ready)
        #expect(engine.engine.isRunning)
    }

    // MARK: Noise reduction (SPEC § 13.4)

    @Test func theChosenLevelOutlivesPrepareAndFallsBackWithoutVoiceProcessing() throws {
        let (engine, _) = try makeEngine()
        engine.setSuppression(.standard)
        #expect(engine.suppression.level == .standard, "kept until the engine runs")
        try engine.prepare(.mono(channels: [0]))
        #expect(engine.suppression == SuppressionState(level: .standard, effective: .standard, usesVoiceProcessing: false))
        #expect(engine.suppression.isGateOnly, "offline there is no voice processing: the gate alone")
        engine.setSuppression(.high)
        #expect(engine.suppression.effective == .high)
    }

    @Test func highCleansTheProcessedTakeOnly() async throws {
        let noise = TestSignal.noise(amplitude: 0.05, frames: 96_000)
        let (engine, _) = try makeEngine { _, frame in noise[frame % noise.count] }
        engine.setSuppression(.high)
        try engine.prepare(.mono(channels: [0]))
        let folder = TakeFolder(url: try temporaryFolder())
        try render(engine, frames: 48_000)   // RNNoise settles before the take
        try engine.startTake(in: folder)
        try render(engine, frames: 48_000)
        _ = try await engine.finishTake()

        func rms(_ samples: [Float]) -> Float { (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot() }
        let raw = try readSamples(folder.raw).channels[0]
        let processed = try readSamples(folder.processed).channels[0]
        #expect(abs(rms(raw) - rms(Array(noise[48_000...]))) < 1e-4, "the raw take is untouched")
        #expect(20 * log10(rms(Array(processed[..<40_000])) / rms(raw)) < -15)
    }

    // MARK: Backing track (SPEC § 13.6)

    /// A mono 48 kHz backing track whose every frame is distinct: 0.1 + frame × 1e-6.
    private func backingTrack(seconds: Double = 2) throws -> URL {
        let url = try temporaryFolder().appending(path: "backing.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) { buffer.floatChannelData![0][frame] = 0.1 + Float(frame) * 1e-6 }
        try file.write(from: buffer)
        return url
    }

    /// Renders `frames` and returns the engine's output (left channel): only the backing track, the monitor is off.
    private func renderOutput(_ engine: AVRecordingEngine, frames: Int) throws -> [Float] {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.engine.manualRenderingFormat, frameCapacity: 4_096)!
        var output: [Float] = []
        while output.count < frames {
            let count = AVAudioFrameCount(min(4_096, frames - output.count))
            try #require(try engine.engine.renderOffline(count, to: buffer) == .success)
            output += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(count))
        }
        return output
    }

    @Test func theBackingTrackStartsOnTheTakesFirstFrame() async throws {
        let (engine, _) = try makeEngine()
        try engine.loadBackingTrack(try backingTrack())
        #expect(engine.backingTrack.map { abs($0.duration - 2) < 1e-6 } == true)
        try engine.prepare(.mono(channels: [0]))
        let before = try renderOutput(engine, frames: 4_096)
        #expect(before.allSatisfy { $0 == 0 }, "silent before the take: the monitor is off")
        let folder = TakeFolder(url: try temporaryFolder())
        try engine.startTake(in: folder)
        let during = try renderOutput(engine, frames: 9_600)
        let take = try await engine.finishTake()

        // The mixer may scale a mono input; the track's frames keep their order and spacing.
        let scale = during[0] / 0.1
        #expect(scale > 0.5)
        for frame in [0, 1, 100, 4_095, 4_096, 9_599] {
            #expect(abs(during[frame] - scale * (0.1 + Float(frame) * 1e-6)) < 1e-5, "track frame \(frame) plays with take frame \(frame)")
        }
        let raw = try readSamples(folder.raw).channels[0]
        #expect(raw[0] == Self.signal(0, 4_096), "the take starts on the same render frame: 4,096")
        #expect(take.backingTrackStart == 0)
        #expect(raw.allSatisfy { $0 < 0.05 }, "the backing track is never in the take")
    }

    @Test func pausingStopsTheTrackAndResumingPicksItUpWhereTheTakeIs() async throws {
        let (engine, _) = try makeEngine()
        try engine.loadBackingTrack(try backingTrack())
        try engine.prepare(.mono(channels: [0]))
        engine.setBackingTrackStart(0.5)
        try engine.startTake(in: TakeFolder(url: try temporaryFolder()))
        let first = try renderOutput(engine, frames: 4_800)
        engine.pause()
        let paused = try renderOutput(engine, frames: 2_000)
        try engine.resume()
        let second = try renderOutput(engine, frames: 4_800)
        let take = try await engine.finishTake()

        let scale = first[0] / (0.1 + 24_000e-6)
        #expect(abs(first[0] - scale * (0.1 + 24_000e-6)) < 1e-5, "starts half a second in")
        #expect(paused.allSatisfy { $0 == 0 }, "silent while paused")
        #expect(abs(second[0] - scale * (0.1 + Float(24_000 + 4_800) * 1e-6)) < 1e-5, "continues where the take is: 0.5 s + 4,800 frames")
        #expect(take.backingTrackStart == 0.5)
        #expect(take.duration == 0.2)
    }

    @Test func theTrackIsLockedDuringATake() throws {
        let (engine, _) = try makeEngine()
        let url = try backingTrack()
        try engine.loadBackingTrack(url)
        try engine.prepare(.mono(channels: [0]))
        try engine.startTake(in: TakeFolder(url: try temporaryFolder()))
        engine.setBackingTrackStart(1)
        #expect(engine.backingTrackStart == 0)
        engine.removeBackingTrack()
        #expect(engine.backingTrack != nil)
        #expect(throws: RecordingError.takeInProgress) { try engine.loadBackingTrack(url) }
        engine.setBackingTrackVolume(0.3)
        #expect(engine.backingTrackVolume == 0.3, "the volume can change any time")
    }

    @Test func anUnreadableTrackIsRefused() throws {
        let (engine, _) = try makeEngine()
        let url = try temporaryFolder().appending(path: "notes.caf")
        try Data("not audio".utf8).write(to: url)
        #expect(throws: RecordingError.cantReadBackingTrack) { try engine.loadBackingTrack(url) }
        #expect(engine.backingTrack == nil)
    }
}
