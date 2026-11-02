import AudioToolbox
import AVFoundation
@testable import EchoCore
import Foundation
import Synchronization
import Testing

struct AudioExportSettingsTests {
    @Test func presetsMatchTheSpec() {
        #expect(AudioExportSettings.standard == AudioExportSettings(format: .aac, sampleRate: 48_000, bitDepth: nil, bitrate: 192_000))
        #expect(AudioExportSettings.high == AudioExportSettings(format: .aac, sampleRate: 48_000, bitDepth: nil, bitrate: 320_000))
        #expect(AudioExportSettings.lossless == AudioExportSettings(format: .flac, sampleRate: 48_000, bitDepth: 24, bitrate: nil))
    }

    @Test func onlyTheOfferedChoicesAreSupported() {
        #expect(AudioExportSettings(format: .wav, sampleRate: 44_100, bitDepth: 16, bitrate: nil).isSupported)
        #expect(AudioExportSettings(format: .aac, sampleRate: 44_100, bitDepth: nil, bitrate: 128_000).isSupported)
        #expect(!AudioExportSettings(format: .wav, sampleRate: 48_000, bitDepth: 20, bitrate: nil).isSupported)
        #expect(!AudioExportSettings(format: .flac, sampleRate: 96_000, bitDepth: 24, bitrate: nil).isSupported)
        #expect(!AudioExportSettings(format: .aac, sampleRate: 48_000, bitDepth: nil, bitrate: 100_000).isSupported)
        #expect(!AudioExportSettings(format: .alac, sampleRate: 48_000, bitDepth: nil, bitrate: nil).isSupported)
    }

    @Test func settingsRoundTripThroughJSON() throws {
        let settings = AudioExportSettings(format: .alac, sampleRate: 44_100, bitDepth: 16, bitrate: nil)
        let decoded = try JSONDecoder().decode(AudioExportSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }
}

final class AudioEncoderTests {
    private let directory: URL

    init() throws {
        directory = try TestMedia.makeDirectory()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ channels: [[Float]]) throws -> URL {
        let url = directory.appending(path: "input-\(UUID().uuidString).caf")
        try TestMedia.writeSamples(channels, to: url)
        return url
    }

    private func encode(_ channels: [[Float]], _ settings: AudioExportSettings, progress: @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let output = directory.appending(path: "output-\(UUID().uuidString).\(settings.format.fileExtension)")
        try await AudioEncoder().encode(try write(channels), to: output, settings: settings, progress: progress)
        return output
    }

    private func container(of url: URL) throws -> AudioFileTypeID {
        var file: AudioFileID?
        try #require(AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr)
        defer { AudioFileClose(file!) }
        var type: AudioFileTypeID = 0
        var size = UInt32(MemoryLayout<AudioFileTypeID>.size)
        try #require(AudioFileGetProperty(file!, kAudioFilePropertyFileFormat, &size, &type) == noErr)
        return type
    }

    /// Encoded audio only, without the container (an M4A file carries a fixed-size header and padding).
    private func audioDataBytes(of url: URL) throws -> UInt64 {
        var file: AudioFileID?
        try #require(AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr)
        defer { AudioFileClose(file!) }
        var bytes: UInt64 = 0
        var size = UInt32(MemoryLayout<UInt64>.size)
        try #require(AudioFileGetProperty(file!, kAudioFilePropertyAudioDataByteCount, &size, &bytes) == noErr)
        return bytes
    }

    private func maxDifference(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).map { abs($0 - $1) }.max() ?? .infinity
    }

    @Test(arguments: AudioFormat.allCases)
    func eachFormatHasItsContainerAndCodec(_ format: AudioFormat) async throws {
        let tone = TestSignal.sine(440, amplitude: 0.25, frames: 48_000)
        let settings = format == .aac
            ? AudioExportSettings(format: .aac, sampleRate: 48_000, bitDepth: nil, bitrate: 256_000)
            : AudioExportSettings(format: format, sampleRate: 48_000, bitDepth: 24, bitrate: nil)

        let output = try await encode([tone, tone], settings)

        let expected: (AudioFileTypeID, AudioFormatID, String) = switch format {
        case .aac: (kAudioFileM4AType, kAudioFormatMPEG4AAC, "m4a")
        case .wav: (kAudioFileWAVEType, kAudioFormatLinearPCM, "wav")
        case .flac: (kAudioFileFLACType, kAudioFormatFLAC, "flac")
        case .alac: (kAudioFileM4AType, kAudioFormatAppleLossless, "m4a")
        }
        #expect(format.fileExtension == expected.2)
        #expect(try container(of: output) == expected.0)
        let file = try AVAudioFile(forReading: output)
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == expected.1)
        #expect(file.fileFormat.channelCount == 2)
        #expect(file.fileFormat.sampleRate == 48_000)
    }

    @Test(arguments: [AudioFormat.wav, .flac, .alac])
    func twentyFourBitLosslessKeepsEverySample(_ format: AudioFormat) async throws {
        let input = [TestSignal.speechLike(frames: 96_000).map { $0 * 0.8 }, TestSignal.sine(997, amplitude: 0.3, frames: 96_000)]

        let output = try await encode(input, AudioExportSettings(format: format, sampleRate: 48_000, bitDepth: 24, bitrate: nil))

        if format == .wav {
            #expect(try AVAudioFile(forReading: output).fileFormat.streamDescription.pointee.mBitsPerChannel == 24)
        }
        let result = try AIProcessorTests.read(output)
        #expect(result[0].count == 96_000)
        #expect(maxDifference(result[0], input[0]) < 1e-6)
        #expect(maxDifference(result[1], input[1]) < 1e-6)
    }

    @Test(arguments: [AudioFormat.flac, .alac], [16, 24])
    func losslessCodecsStoreTheChosenBitDepth(_ format: AudioFormat, _ bitDepth: Int) async throws {
        let output = try await encode(
            [TestSignal.sine(440, amplitude: 0.25, frames: 4_800)],
            AudioExportSettings(format: format, sampleRate: 48_000, bitDepth: bitDepth, bitrate: nil)
        )
        // FLAC and ALAC share the source bit depth flags.
        let flags = try AVAudioFile(forReading: output).fileFormat.streamDescription.pointee.mFormatFlags
        #expect(flags == (bitDepth == 16 ? kAppleLosslessFormatFlag_16BitSourceData : kAppleLosslessFormatFlag_24BitSourceData))
    }

    @Test func sixteenBitIsCloseToTheInput() async throws {
        let input = TestSignal.speechLike(frames: 48_000).map { $0 * 0.8 }

        let output = try await encode([input], AudioExportSettings(format: .wav, sampleRate: 48_000, bitDepth: 16, bitrate: nil))

        #expect(try AVAudioFile(forReading: output).fileFormat.streamDescription.pointee.mBitsPerChannel == 16)
        #expect(maxDifference(try AIProcessorTests.read(output)[0], input) <= 2.5 / 32_768, "rounding plus ±1 LSB dither")
    }

    @Test func sixteenBitIsDitheredSoQuietDetailSurvives() async throws {
        // 0.4 LSB of 16-bit: plain rounding turns it into silence; TPDF dither keeps it, on average, in the noise.
        let tone = TestSignal.sine(1_000, amplitude: 0.4 / 32_768, frames: 48_000)

        let result = try AIProcessorTests.read(try await encode([tone], AudioExportSettings(format: .flac, sampleRate: 48_000, bitDepth: 16, bitrate: nil)))[0]

        let projection = zip(result, tone).map { Double($0 * $1) }.reduce(0, +) / tone.map { Double($0 * $0) }.reduce(0, +)
        #expect(abs(projection - 1) < 0.1)
    }

    @Test func resamplesTo44_1kHz() async throws {
        let tone = TestSignal.sine(1_000, amplitude: 0.5, frames: 96_000)

        let output = try await encode([tone, tone], AudioExportSettings(format: .wav, sampleRate: 44_100, bitDepth: 24, bitrate: nil))

        #expect(try AVAudioFile(forReading: output).fileFormat.sampleRate == 44_100)
        let result = try AIProcessorTests.read(output)[0]
        #expect(abs(result.count - 88_200) <= 2)
        let middle = Array(result[4_410..<(result.count - 4_410)])
        let rms = sqrt(middle.map { Double($0 * $0) }.reduce(0, +) / Double(middle.count))
        #expect(abs(20 * log10(rms / (0.5 / 2.squareRoot()))) < 0.05, "level kept")
        let rising = zip(middle, middle.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        #expect(abs(rising - Int(Double(middle.count) / 44.1)) <= 2, "still 1 kHz")
    }

    @Test(arguments: AudioExportSettings.aacBitrates)
    func aacUsesTheChosenBitrate(_ bitrate: Int) async throws {
        var seed: UInt32 = 7
        let noise = (0..<(48_000 * 5)).map { _ -> Float in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.2
        }

        let output = try await encode([noise, noise.reversed()], AudioExportSettings(format: .aac, sampleRate: 48_000, bitDepth: nil, bitrate: bitrate))

        let rate = Double(try audioDataBytes(of: output) * 8) / 5
        #expect(abs(rate / Double(bitrate) - 1) < 0.1, "measured \(rate)")
        let length = try AVAudioFile(forReading: output).length
        #expect(abs(length - 240_000) <= 1, "encoder priming and padding are trimmed on read")
    }

    @Test func monoAACAtTheHighestBitrateStillEncodes() async throws {
        let output = try await encode([TestSignal.speechLike(frames: 48_000)], .high)
        let file = try AVAudioFile(forReading: output)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
    }

    @Test func progressRunsFromZeroToOne() async throws {
        let values = Mutex<[Double]>([])
        _ = try await encode([TestSignal.sine(440, amplitude: 0.2, frames: 48_000 * 3)], AudioExportSettings(format: .wav, sampleRate: 44_100, bitDepth: 16, bitrate: nil)) { value in
            values.withLock { $0.append(value) }
        }
        let reported = values.withLock { $0 }
        #expect(reported.first == 0)
        #expect(reported.last == 1)
        #expect(reported.count > 2)
        #expect(zip(reported, reported.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func cancellingLeavesNoFile() async throws {
        let input = try write([TestSignal.sine(440, amplitude: 0.2, frames: 48_000 * 60)])
        let output = directory.appending(path: "cancelled.flac")

        let task = Task { try await AudioEncoder().encode(input, to: output, settings: .lossless, progress: { _ in }) }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: output.path()))
    }

    @Test func anUnreadableInputFailsWithoutAFile() async throws {
        let output = directory.appending(path: "never.m4a")
        await #expect(throws: ExportError.unreadableAudio) {
            try await AudioEncoder().encode(self.directory.appending(path: "missing.m4a"), to: output, settings: .standard, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: output.path()))
    }

    @Test func unsupportedSettingsAreRefused() async throws {
        let input = try write([TestSignal.sine(440, amplitude: 0.2, frames: 4_800)])
        let output = directory.appending(path: "never.wav")
        await #expect(throws: ExportError.unsupportedSettings) {
            try await AudioEncoder().encode(input, to: output, settings: AudioExportSettings(format: .wav, sampleRate: 48_000, bitDepth: 20, bitrate: nil), progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: output.path()))
    }
}
