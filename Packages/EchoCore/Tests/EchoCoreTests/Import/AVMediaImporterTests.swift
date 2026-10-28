import AVFoundation
import EchoCore
import Foundation
import ImageIO
import Synchronization
import Testing

private final class ProgressLog: Sendable {
    let values = Mutex<[Double]>([])

    func record(_ value: Double) {
        values.withLock { $0.append(value) }
    }
}

final class AVMediaImporterTests {
    private let directory: URL
    private let folder: ProjectFolder
    private let importer = AVMediaImporter()

    init() throws {
        directory = try TestMedia.makeDirectory()
        folder = ProjectFolder(url: directory.appending(path: "Project", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func importFile(_ url: URL, progress: ProgressLog = ProgressLog()) async throws -> ImportedMedia {
        let inspection = try await AVMediaInspector().inspect(url)
        return try await importer.importMedia(from: url, inspection: inspection, into: folder, progress: progress.record)
    }

    private func folderContents() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.url.path))
    }

    @Test func copiesTheSourceUnchangedAndExtracts48kFloatWorkingAudio() async throws {
        let original = directory.appending(path: "voice.wav")
        try TestMedia.writeTone(to: original, seconds: 1, channels: 2, sampleRate: 44_100)
        #expect(try await AVMediaInspector().inspect(original).sourceInfo.sampleRate == 44_100)

        let imported = try await importFile(original)

        #expect(imported.sourceFileName == "source.wav")
        #expect(try Data(contentsOf: folder.source(fileName: "source.wav")) == Data(contentsOf: original))
        let working = try AVAudioFile(forReading: folder.working)
        #expect(working.fileFormat.sampleRate == 48_000)
        #expect(working.fileFormat.channelCount == 2)
        #expect(working.fileFormat.commonFormat == .pcmFormatFloat32)
        #expect(abs(Double(working.length) - 48_000) < 480)
        #expect(imported.workingChannelCount == 2)
        #expect(try folderContents() == ["source.wav", "working.caf", "waveform-overview.json"])
    }

    @Test func overviewHasOnePeakPerBucket() async throws {
        let original = directory.appending(path: "voice.wav")
        try TestMedia.writeTone(to: original, seconds: 1, channels: 1)

        let imported = try await importFile(original)

        #expect(imported.overview.count == AVMediaImporter.overviewBucketCount)
        #expect(imported.overview.allSatisfy { $0 > 0.2 && $0 <= 0.26 }, "a steady 0.25 tone fills every bucket")
        let stored = try JSONDecoder().decode([Float].self, from: Data(contentsOf: folder.waveformOverview))
        #expect(stored == imported.overview)
    }

    @Test func monoStaysMono() async throws {
        let original = directory.appending(path: "mono.caf")
        try TestMedia.writeTone(to: original, seconds: 1, channels: 1)

        let imported = try await importFile(original)

        #expect(imported.workingChannelCount == 1)
        #expect(try AVAudioFile(forReading: folder.working).fileFormat.channelCount == 1)
    }

    @Test func moreThanTwoChannelsAreDownmixedToStereo() async throws {
        let original = directory.appending(path: "surround.caf")
        try TestMedia.writeTone(to: original, seconds: 1, channels: 6)
        #expect(try await AVMediaInspector().inspect(original).sourceInfo.channelCount == 6)

        let imported = try await importFile(original)

        #expect(imported.workingChannelCount == 2)
        #expect(try AVAudioFile(forReading: folder.working).fileFormat.channelCount == 2)
    }

    @Test func videoGetsAFrameThumbnail() async throws {
        let original = directory.appending(path: "vlog.mov")
        try await TestMedia.writeMovie(to: original, seconds: 2, withAudio: true)

        _ = try await importFile(original)

        let source = try #require(CGImageSourceCreateWithURL(folder.thumbnail as CFURL, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
        #expect(try folderContents() == ["source.mov", "working.caf", "waveform-overview.json", "thumbnail.jpg"])
    }

    @Test func progressRisesToOne() async throws {
        let original = directory.appending(path: "voice.wav")
        try TestMedia.writeTone(to: original, seconds: 2, channels: 2)
        let progress = ProgressLog()

        _ = try await importFile(original, progress: progress)

        let values = progress.values.withLock { $0 }
        #expect(values.last == 1)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func cancellationRemovesEverythingItWrote() async throws {
        let original = directory.appending(path: "voice.wav")
        try TestMedia.writeTone(to: original, seconds: 1, channels: 2)
        let inspection = try await AVMediaInspector().inspect(original)

        let task = Task { [importer, folder] in
            try await importer.importMedia(from: original, inspection: inspection, into: folder) { _ in }
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try folderContents().isEmpty)
    }

    @Test func unreadableContentsRemoveEverythingItWrote() async throws {
        let original = directory.appending(path: "voice.wav")
        try TestMedia.writeTone(to: original, seconds: 1, channels: 2)
        let inspection = try await AVMediaInspector().inspect(original)
        try Data("no longer audio".utf8).write(to: original)

        await #expect(throws: ImportError.unreadable) {
            try await importer.importMedia(from: original, inspection: inspection, into: folder) { _ in }
        }
        #expect(try folderContents().isEmpty)
    }
}
