import AVFoundation
import EchoAudioUnits
import Foundation
import Testing
@testable import EchoCore

struct CAFWriterTests {
    private func append(_ writer: CAFWriter, _ channels: [[Float]]) throws {
        let pointers = channels.map { channel -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: channel.count)
            pointer.initialize(from: channel, count: channel.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        try writer.append(pointers.map { UnsafePointer($0) }, frames: channels[0].count)
    }

    @Test func writesFloatSamplesThatCoreAudioReadsBack() throws {
        let url = try temporaryFolder().appending(path: "stereo.caf")
        let writer = try CAFWriter(url: url, sampleRate: 48_000, channelCount: 2)
        let left = (0..<1_000).map { Float($0) / 1_000 }, right = (0..<1_000).map { -Float($0) / 2_000 }
        try append(writer, [Array(left[..<600]), Array(right[..<600])])
        try append(writer, [Array(left[600...]), Array(right[600...])])
        try writer.close()

        let (format, channels) = try readSamples(url)
        #expect(format.sampleRate == 48_000)
        #expect(format.channelCount == 2)
        #expect(format.commonFormat == .pcmFormatFloat32)
        #expect(channels == [left, right])
        #expect(writer.frameCount == 1_000)
    }

    @Test func aFileThatWasNeverClosedKeepsEverythingWritten() throws {
        let url = try temporaryFolder().appending(path: "crashed.caf")
        let samples = (0..<4_800).map { sin(Float($0) * 0.05) * 0.5 }
        do {
            // Dropped without `close()`, as when the app is killed mid-take: the data size stays unknown.
            let writer = try CAFWriter(url: url, sampleRate: 48_000, channelCount: 1)
            try append(writer, [samples])
            try writer.synchronize()
        }
        #expect(try readSamples(url).channels == [samples])
    }

    @Test func neverReplacesAnExistingFile() throws {
        let url = try temporaryFolder().appending(path: "existing.caf")
        try Data("keep".utf8).write(to: url)
        #expect(throws: (any Error).self) { try CAFWriter(url: url, sampleRate: 48_000, channelCount: 1) }
        #expect(try Data(contentsOf: url) == Data("keep".utf8))
    }
}

struct TakeWriterTests {
    private let files = FileManager()

    /// The processed file follows the raw file's timeline at the same length; its last moment, still inside the live
    /// chain when the take ended, is silent.
    private func expectProcessedFollows(_ raw: [Float], _ processed: [Float], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(processed.count == raw.count, sourceLocation: sourceLocation)
        #expect(alignment(raw, processed, over: 4_800..<(raw.count - 2_000)) > 0.99, sourceLocation: sourceLocation)
        #expect(processed.suffix(processedLatency48k).allSatisfy { $0 == 0 }, sourceLocation: sourceLocation)
    }

    /// Configures a core for `configuration` on an input of `inputs` channels at `rate`, captures `frames` frames of
    /// `signal`, then writes the take.
    private func record(
        _ configuration: RecordingConfiguration, inputs: Int, rate: Double = 48_000, frames: Int,
        signal: @escaping (Int, Int) -> Float
    ) async throws -> RecordedTake {
        let core = CaptureCore()
        try #require(core.configure(
            sampleRate: rate, inputChannelCount: inputs, channels: configuration.channels,
            mixdownChannelCount: configuration.mixdownChannelCount, maximumFrames: 512, ringFrames: frames + 512
        ))
        let folder = TakeFolder(url: try temporaryFolder())
        let writer = try TakeWriter(core: core, folder: folder, configuration: configuration)
        let harness = CaptureHarness(core: core, frames: 512)
        core.setCapturing(true)
        var start = 0
        while start < frames {
            let count = min(512, frames - start)
            harness.fill(count) { channel, frame in signal(channel, start + frame) }
            harness.process(count)
            start += count
            if start.isMultiple(of: 8_192) { try await writer.drain() }
        }
        core.setCapturing(false)
        return await writer.finish()
    }

    private func fileNames(_ take: RecordedTake) throws -> Set<String> {
        Set(try files.contentsOfDirectory(atPath: take.folder.url.path()))
    }

    @Test func oneChannelMakesRawAndProcessedOnly() async throws {
        let take = try await record(.mono(channels: [1]), inputs: 2, frames: 24_000) { channel, frame in
            Float(channel + 1) * 0.25 * sin(Float(frame) * 0.01)
        }
        #expect(try fileNames(take) == ["raw.caf", "processed.caf"])
        #expect(take.duration == 0.5)
        #expect(take.mixdownChannelCount == 1)
        #expect(take.channelFileCount == 0)
        let expected = (0..<24_000).map { 0.5 * sin(Float($0) * 0.01) }
        #expect(try readSamples(take.folder.raw).channels == [expected])
        expectProcessedFollows(expected, try readSamples(take.folder.processed).channels[0])
    }

    @Test func severalChannelsAreSummedAndEachKeptInTakeOrder() async throws {
        let signal: (Int, Int) -> Float = { channel, frame in Float(channel + 1) * 0.1 + Float(frame % 100) * 1e-3 }
        let take = try await record(.mono(channels: [2, 0]), inputs: 3, frames: 10_000, signal: signal)

        #expect(try fileNames(take) == ["raw.caf", "processed.caf", "ch1.caf", "ch2.caf"])
        #expect(take.channelFileCount == 2)
        #expect(take.channelFiles == [take.folder.channel(1), take.folder.channel(2)])
        let first = (0..<10_000).map { signal(2, $0) }, second = (0..<10_000).map { signal(0, $0) }
        #expect(try readSamples(take.folder.channel(1)).channels == [first])
        #expect(try readSamples(take.folder.channel(2)).channels == [second])
        let sum = zip(first, second).map(+)
        #expect(try readSamples(take.folder.raw).channels == [sum])
        expectProcessedFollows(sum, try readSamples(take.folder.processed).channels[0])
    }

    @Test func builtInStereoRecordsAStereoMixdown() async throws {
        let take = try await record(.builtInStereo, inputs: 2, frames: 4_800) { channel, _ in channel == 0 ? 0.3 : -0.2 }
        #expect(try fileNames(take) == ["raw.caf", "processed.caf"])
        #expect(take.mixdownChannelCount == 2)
        let raw = try readSamples(take.folder.raw)
        #expect(raw.format.channelCount == 2)
        #expect(raw.channels == [[Float](repeating: 0.3, count: 4_800), [Float](repeating: -0.2, count: 4_800)])
    }

    @Test func inputAtAnotherRateIsWrittenAt48kHz() async throws {
        // A Bluetooth headset at 16 kHz: one second of a 440 Hz tone.
        let take = try await record(.mono(channels: [0]), inputs: 1, rate: 16_000, frames: 16_000) { _, frame in
            0.5 * sin(2 * .pi * 440 * Float(frame) / 16_000)
        }
        let raw = try readSamples(take.folder.raw)
        #expect(raw.format.sampleRate == 48_000)
        #expect(abs(raw.channels[0].count - 48_000) <= 64)
        #expect(abs(take.duration - 1) < 0.002)
        // Still 440 Hz: upward zero crossings over the middle half second.
        let middle = raw.channels[0][12_000..<36_000]
        let crossings = zip(middle, middle.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        #expect(abs(crossings - 220) <= 1)
    }

    @Test func neverTouchesFilesAlreadyInTheFolder() throws {
        let folder = TakeFolder(url: try temporaryFolder())
        try Data("earlier take".utf8).write(to: folder.processed)
        let core = CaptureCore()
        try #require(core.configure(sampleRate: 48_000, inputChannelCount: 2, channels: [0, 1], mixdownChannelCount: 1, maximumFrames: 512, ringFrames: 4_096))

        #expect(throws: RecordingError.cantCreateFiles) {
            try TakeWriter(core: core, folder: folder, configuration: .mono(channels: [0, 1]))
        }
        #expect(try files.contentsOfDirectory(atPath: folder.url.path()) == ["processed.caf"], "raw.caf it made is removed again")
        #expect(try Data(contentsOf: folder.processed) == Data("earlier take".utf8))
    }
}

struct RecordingConfigurationTests {
    @Test func validatesChannelsAgainstTheInput() {
        #expect(RecordingConfiguration.mono(channels: [0]).isValid(forInputChannelCount: 1))
        #expect(!RecordingConfiguration.mono(channels: [1]).isValid(forInputChannelCount: 1))
        #expect(!RecordingConfiguration.mono(channels: []).isValid(forInputChannelCount: 2))
        #expect(!RecordingConfiguration.mono(channels: [0, 0]).isValid(forInputChannelCount: 2))
        #expect(RecordingConfiguration.builtInStereo.isValid(forInputChannelCount: 2))
        #expect(!RecordingConfiguration.builtInStereo.isValid(forInputChannelCount: 1))
        #expect(!RecordingConfiguration(channels: [0, 1, 2], mixdown: .stereo).isValid(forInputChannelCount: 3))
    }

    @Test func channelFilesOnlyForSeveralSummedChannels() {
        #expect(!RecordingConfiguration.mono(channels: [0]).writesChannelFiles)
        #expect(RecordingConfiguration.mono(channels: [0, 3]).writesChannelFiles)
        #expect(!RecordingConfiguration.builtInStereo.writesChannelFiles, "left and right are already in raw.caf")
        #expect(RecordingConfiguration.builtInStereo.mixdownChannelCount == 2)
    }
}

struct RecordingMetadataTests {
    @Test func manifestsWithoutTheParameterLogStillOpen() throws {
        let json = #"{"channelNames": ["Host"], "editingSource": "processed", "markers": []}"#
        let metadata = try JSONDecoder().decode(RecordingMetadata.self, from: Data(json.utf8))
        #expect(metadata == RecordingMetadata(channelNames: ["Host"]))
    }

    @Test func theLogRoundTrips() throws {
        let metadata = RecordingMetadata(
            channelNames: [], markers: [.init(time: 2, kind: .processingChange)],
            parameterChanges: [.init(time: 1.5, parameter: .inputGain, value: 6)]
        )
        #expect(try JSONDecoder().decode(RecordingMetadata.self, from: JSONEncoder().encode(metadata)) == metadata)
    }
}
