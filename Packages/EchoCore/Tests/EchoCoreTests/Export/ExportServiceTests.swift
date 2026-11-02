import AVFoundation
@testable import EchoCore
import EchoCoreFakes
import Foundation
import Synchronization
import Testing

struct ExportOutputTests {
    private func choices(_ kind: ExportKind, _ quality: AudioQuality, custom: AudioExportSettings? = nil) -> ExportChoices {
        var choices = ExportChoices.defaults(for: .video)
        choices.kind = kind
        choices.quality = quality
        if let custom { choices.custom = custom }
        return choices
    }

    @Test func eachQualityPicksTheAudioFileSettings() {
        #expect(choices(.audioOnly, .standard).audioSettings == .standard)
        #expect(choices(.audioOnly, .high).audioSettings == .high)
        #expect(choices(.audioOnly, .lossless).audioSettings == .lossless)
        let wav = AudioExportSettings(format: .wav, sampleRate: 44_100, bitDepth: 16, bitrate: nil)
        #expect(choices(.audioOnly, .custom, custom: wav).audioSettings == wav)
    }

    @Test func theAudioInsideAVideoIsAACAtThePresetsBitrate() {
        // User decision (SPEC § 11.1): Standard 192, High 320, Lossless 320, Custom its AAC bitrate or 256.
        #expect(choices(.video, .standard).videoAudioBitrate == 192_000)
        #expect(choices(.video, .high).videoAudioBitrate == 320_000)
        #expect(choices(.video, .lossless).videoAudioBitrate == 320_000)
        let aac128 = AudioExportSettings(format: .aac, sampleRate: 48_000, bitDepth: nil, bitrate: 128_000)
        #expect(choices(.video, .custom, custom: aac128).videoAudioBitrate == 128_000)
        let flac = AudioExportSettings(format: .flac, sampleRate: 48_000, bitDepth: 16, bitrate: nil)
        #expect(choices(.video, .custom, custom: flac).videoAudioBitrate == 256_000)
    }

    @Test func theKindDecidesWhatIsMade() {
        #expect(choices(.video, .high).output(for: .video) == .video(audioBitrate: 320_000))
        #expect(choices(.audioOnly, .lossless).output(for: .video) == .audioOnly(.lossless))
        #expect(choices(.both, .standard).output(for: .video) == .both(audioBitrate: 192_000, .standard))
    }

    @Test func audioProjectsAlwaysMakeAudioOnly() {
        #expect(choices(.video, .high).output(for: .audio) == .audioOnly(.high))
        #expect(choices(.both, .standard).output(for: .audio) == .audioOnly(.standard))
    }
}

final class AVExportServiceTests {
    private let directory: URL
    private let renderer = FakeFinalRenderer()
    private let encoder = FakeAudioEncoder()
    private let remuxer = FakeVideoRemuxer()

    init() throws {
        directory = try TestMedia.makeDirectory()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private var service: AVExportService {
        AVExportService(renderer: renderer, encoder: encoder, remuxer: remuxer)
    }

    private func job(_ output: ExportOutput, video: Bool = true) throws -> ExportJob {
        let audio = directory.appending(path: "render.m4a")
        try Data("render".utf8).write(to: audio)
        var source: URL?
        if video {
            source = directory.appending(path: "source.mov")
            try Data("video".utf8).write(to: source!)
        }
        var manual = ManualSettings()
        manual.inputGainDB = 3
        return ExportJob(
            audio: audio, sourceVideo: source, manual: manual, trimRange: TimeRangeCodable(start: 1, duration: 2),
            outputLoudness: .podcast, output: output, title: "Interview: take 2", fallbackTitle: "Export"
        )
    }

    private func makeFolder() throws -> URL {
        let folder = directory.appending(path: "export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func aVideoIsRenderedEncodedAndRemuxed() async throws {
        let job = try job(.video(audioBitrate: 320_000))
        let folder = try makeFolder()

        let files = try await service.export(job, into: folder, progress: { _ in })

        let request = try #require(await renderer.requests.first)
        #expect(request == FinalRenderRequest(audio: job.audio, manual: job.manual, trimRange: job.trimRange, outputLoudness: .podcast))
        #expect(await encoder.encoded == [AudioExportSettings(format: .aac, sampleRate: 48_000, bitDepth: nil, bitrate: 320_000)])
        let remux = try #require(await remuxer.requests.first)
        #expect(remux.video == job.sourceVideo)
        #expect(remux.trimRange == job.trimRange)
        #expect(files == ExportedFiles(video: folder.appending(path: "Interview- take 2.mov"), audio: nil))
        #expect(FileManager.default.fileExists(atPath: files.video!.path(percentEncoded: false)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path()) == ["Interview- take 2.mov"], "work files are gone")
    }

    @Test func audioOnlyIsEncodedInTheChosenFormat() async throws {
        let folder = try makeFolder()

        let files = try await service.export(try job(.audioOnly(.lossless), video: false), into: folder, progress: { _ in })

        #expect(await encoder.encoded == [.lossless])
        #expect(await remuxer.requests.isEmpty)
        #expect(files == ExportedFiles(video: nil, audio: folder.appending(path: "Interview- take 2.flac")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path()) == ["Interview- take 2.flac"])
    }

    @Test func bothMakesTheVideoAndTheAudioFile() async throws {
        let folder = try makeFolder()

        let files = try await service.export(try job(.both(audioBitrate: 192_000, .high)), into: folder, progress: { _ in })

        #expect(await encoder.encoded == [AudioExportSettings(format: .aac, sampleRate: 48_000, bitDepth: nil, bitrate: 192_000), .high])
        #expect(files.video == folder.appending(path: "Interview- take 2.mov"))
        #expect(files.audio == folder.appending(path: "Interview- take 2.m4a"))
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: folder.path())) == ["Interview- take 2.mov", "Interview- take 2.m4a"])
    }

    @Test func aVideoNeedsItsSource() async throws {
        await #expect(throws: ExportError.unreadableVideo) {
            try await self.service.export(try self.job(.video(audioBitrate: 192_000), video: false), into: try self.makeFolder(), progress: { _ in })
        }
    }

    @Test func failuresComeThrough() async throws {
        await remuxer.setError(ExportError.cantWrite)
        await #expect(throws: ExportError.cantWrite) {
            try await self.service.export(try self.job(.video(audioBitrate: 192_000)), into: try self.makeFolder(), progress: { _ in })
        }
    }

    @Test func progressRunsOnceFromZeroToOne() async throws {
        let values = Mutex<[Double]>([])
        _ = try await service.export(try job(.both(audioBitrate: 192_000, .high)), into: try makeFolder()) { value in
            values.withLock { $0.append(value) }
        }
        let reported = values.withLock { $0 }
        #expect(reported.first == 0)
        #expect(reported.last == 1)
        #expect(zip(reported, reported.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func theRealPipelineMakesAVideoWithTheNewAudioAndAnAudioFile() async throws {
        let video = directory.appending(path: "clip.mov")
        try await TestMedia.writeMovie(to: video, seconds: 3, withAudio: true)
        let working = directory.appending(path: "working.caf")
        let tone = TestSignal.sine(1_000, amplitude: 0.2, frames: 48_000 * 3)
        try TestMedia.writeSamples([tone, tone], to: working)
        let job = ExportJob(
            audio: working, sourceVideo: video, manual: ManualSettings(), trimRange: TimeRangeCodable(start: 0.5, duration: 2),
            outputLoudness: nil, output: .both(audioBitrate: 256_000, .lossless), title: "Clip", fallbackTitle: "Export"
        )
        let real = AVExportService(renderer: FinalRenderer(autoLevel: AutoLevelAnalyzer()), encoder: AudioEncoder(), remuxer: VideoRemuxer())

        let files = try await real.export(job, into: try makeFolder(), progress: { _ in })

        let movie = AVURLAsset(url: try #require(files.video))
        #expect(abs(try await movie.load(.duration).seconds - 2) < 0.1)
        #expect(try await movie.loadTracks(withMediaType: .audio).count == 1)
        let flac = try AVAudioFile(forReading: try #require(files.audio))
        #expect(flac.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatFLAC)
        #expect(flac.length == 96_000)
    }
}
