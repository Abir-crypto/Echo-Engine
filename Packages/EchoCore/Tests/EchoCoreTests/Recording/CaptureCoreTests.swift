import CEchoDSPTestSupport
import EchoAudioUnits
import Testing

struct CaptureCoreTests {
    private func core(inputs: Int, channels: [Int], mixdown: Int, maximumFrames: Int = 512, ringFrames: Int = 48_000) throws -> CaptureCore {
        let core = CaptureCore()
        core.setParameterForTesting(.monitorGain, 1)   // these tests read the monitor output
        try #require(core.configure(
            sampleRate: 48_000, inputChannelCount: inputs, channels: channels, mixdownChannelCount: mixdown,
            maximumFrames: maximumFrames, ringFrames: ringFrames
        ))
        return core
    }

    @Test func monoMixdownSumsTheSelectedChannelsAndQueuesThemInTakeOrder() throws {
        let harness = CaptureHarness(core: try core(inputs: 3, channels: [2, 0], mixdown: 1), frames: 512)
        harness.fill(256) { channel, frame in Float(channel + 1) * 0.1 + Float(frame) * 1e-4 }
        harness.core.setCapturing(true)
        harness.process(256)

        let output = harness.output(256)
        #expect(output.count == 1)
        // The monitor is the mixdown through the live chain: the limiter's 72-frame look-ahead, the leveler barely moved.
        #expect(abs(output[0][10 + 72] - (Float(3) * 0.1 + 10e-4 + (Float(1) * 0.1 + 10e-4))) < 1e-3, "channel 3 + channel 1")
        let planes = harness.readAll()
        #expect(planes.count == 3, "two raw channels, then the processed mixdown")
        #expect(planes[0][10] == Float(3) * 0.1 + 10e-4)
        #expect(planes[1][10] == Float(1) * 0.1 + 10e-4)
        #expect(planes[2] == [Float](repeating: 0, count: 256), "the processed mixdown runs the live chain's latency behind")
        #expect(harness.core.processedLatencyFrames == processedLatency48k)
        #expect(harness.core.capturedFrames == 256)
    }

    @Test func stereoMixdownKeepsLeftAndRight() throws {
        let harness = CaptureHarness(core: try core(inputs: 2, channels: [0, 1], mixdown: 2), frames: 512)
        harness.fill(128) { channel, _ in channel == 0 ? 0.25 : -0.5 }
        harness.core.setCapturing(true)
        harness.process(128)

        #expect(harness.output(128).map { $0[100] }.enumerated().allSatisfy { abs($1 - [0.25, -0.5][$0]) < 1e-3 },
                "left and right, a limiter look-ahead later")
        let planes = harness.readAll()
        #expect(planes.map(\.count) == [128, 128, 128, 128])
        #expect(planes.map { $0[64] } == [0.25, -0.5, 0, 0], "processed is still inside the live chain's latency")
    }

    @Test func metersEveryInputChannelButQueuesNothingWhileNotCapturing() throws {
        let harness = CaptureHarness(core: try core(inputs: 3, channels: [1], mixdown: 1), frames: 512)
        harness.fill(512) { channel, frame in frame == 100 ? [0.5, -0.75, 1.25][channel] : 0.01 }
        harness.process(512)

        #expect(harness.core.takePeaks() == [0.5, 0.75, 1.25])
        #expect(harness.core.takePeaks() == [0, 0, 0], "peaks start over after each read")
        #expect(harness.readAll().allSatisfy { $0.isEmpty })
        #expect(harness.core.capturedFrames == 0)
    }

    @Test func audioTheRingHasNoRoomForBecomesSilenceSoTheTakeKeepsItsLength() throws {
        // A 1,024-frame ring filled by six 256-frame blocks with no reads.
        let harness = CaptureHarness(core: try core(inputs: 1, channels: [0], mixdown: 1, maximumFrames: 256, ringFrames: 1_024), frames: 4_096)
        harness.core.setCapturing(true)
        for block in 1...6 {
            harness.fill(256) { _, _ in Float(block) }
            harness.process(256)
        }
        #expect(harness.core.droppedFrames == 512)

        let first = harness.readAll()[0]
        #expect(first.count == 1_536, "what fit, then silence for what didn't")
        #expect(Set(first[0..<1_024]) == [1, 2, 3, 4])
        #expect(first[1_024...].allSatisfy { $0 == 0 })

        harness.fill(256) { _, _ in 7 }
        harness.process(256)
        #expect(harness.readAll()[0] == [Float](repeating: 7, count: 256))
        #expect(harness.core.capturedFrames == 1_792)
    }

    @Test func refusesInvalidLayouts() {
        let core = CaptureCore()
        func configure(inputs: Int, channels: [Int], mixdown: Int) -> Bool {
            core.configure(sampleRate: 48_000, inputChannelCount: inputs, channels: channels, mixdownChannelCount: mixdown, maximumFrames: 512, ringFrames: 4_096)
        }
        #expect(!configure(inputs: 2, channels: [], mixdown: 1), "no channel")
        #expect(!configure(inputs: 2, channels: [2], mixdown: 1), "beyond the input")
        #expect(!configure(inputs: 2, channels: [1, 1], mixdown: 1), "twice")
        #expect(!configure(inputs: 2, channels: [0], mixdown: 2), "stereo needs two")
        #expect(!configure(inputs: CaptureCore.maximumInputChannels + 1, channels: [0], mixdown: 1), "too many inputs")
        #expect(!core.isConfigured)
        #expect(configure(inputs: CaptureCore.maximumInputChannels, channels: [31, 0], mixdown: 1))
    }

    @Test func anOpenTakeKeepsItsLayout() throws {
        let core = try core(inputs: 2, channels: [0], mixdown: 1)
        core.setTakeOpen(true)
        #expect(!core.configure(sampleRate: 48_000, inputChannelCount: 2, channels: [1], mixdownChannelCount: 1, maximumFrames: 512, ringFrames: 48_000))
        #expect(core.configure(sampleRate: 48_000, inputChannelCount: 2, channels: [0], mixdownChannelCount: 1, maximumFrames: 512, ringFrames: 48_000),
                "the same layout is kept")
        core.setTakeOpen(false)
        #expect(core.configure(sampleRate: 48_000, inputChannelCount: 2, channels: [1], mixdownChannelCount: 1, maximumFrames: 512, ringFrames: 48_000))
    }

    @Test func discardForgetsWhatIsQueued() throws {
        let harness = CaptureHarness(core: try core(inputs: 1, channels: [0], mixdown: 1), frames: 512)
        harness.core.setCapturing(true)
        harness.fill(512) { _, _ in 1 }
        harness.process(512)
        harness.core.setCapturing(false)
        harness.core.discard()
        #expect(harness.readAll().allSatisfy { $0.isEmpty })
    }

    @Test func renderingAndReadingNeverAllocate() throws {
        let harness = CaptureHarness(core: try core(inputs: 4, channels: [3, 1, 0], mixdown: 1, maximumFrames: 256, ringFrames: 512), frames: 256)
        harness.fill(256) { channel, frame in Float(channel) * 0.1 + Float(frame) * 1e-3 }
        harness.core.setCapturing(true)
        var read = 0
        echo.test.beginAllocationGuard()
        for _ in 0..<8 {
            harness.process(256)   // the ring fills up and drops: both paths run
        }
        for _ in 0..<8 { read += harness.readOnce() }
        let allocations = echo.test.endAllocationGuard()
        #expect(allocations == 0)
        #expect(read > 0)
    }
}
