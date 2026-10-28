import AVFoundation
import EchoCore
@testable import EchoEngine
import Foundation
import Testing

/// The real import stack on iOS: AVMediaInspector + AVMediaImporter + FileProjectRepository + StorageEstimator.
@MainActor
final class ImportIntegrationTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "ImportIntegration-\(UUID().uuidString)")

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @Test func wavImportsIntoARealProjectFolder() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "Morning take.wav")
        try writeTone(to: source, seconds: 1, channels: 2)
        let repository = FileProjectRepository(root: root.appending(path: "Projects"), migrator: ProjectMigrator())
        let model = ImportModel(
            inspector: AVMediaInspector(),
            importer: AVMediaImporter(),
            storage: StorageEstimator(volume: root),
            repository: repository,
            dateProvider: SystemClock()
        )

        model.importFile(at: source)
        await model.waitUntilFinished()

        #expect(model.failure == nil)
        let stored = try #require(try await repository.list().first)
        #expect(stored.project.title == "Morning take")
        #expect(stored.project.mediaType == .audio)
        let folder = repository.folder(for: stored.project.id)
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: folder.url.path))
        #expect(files == ["project.json", "source.wav", "working.caf", "waveform-overview.json"])
        #expect(try AVAudioFile(forReading: folder.working).fileFormat.sampleRate == 48_000)
    }

    private func writeTone(to url: URL, seconds: Double, channels: Int) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<channels {
            let samples = try #require(buffer.floatChannelData?[channel])
            for frame in 0..<Int(frames) {
                samples[frame] = 0.25 * sin(2 * .pi * 440 * Float(frame) / 44_100)
            }
        }
        try file.write(from: buffer)
    }
}
