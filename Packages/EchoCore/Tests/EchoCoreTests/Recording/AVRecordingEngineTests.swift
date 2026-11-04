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
        #expect(try readSamples(folder.processed).channels == [first.map { $0 + 0.25 }])
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
}
