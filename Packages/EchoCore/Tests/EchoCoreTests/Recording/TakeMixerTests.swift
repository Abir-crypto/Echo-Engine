import AVFoundation
import EchoCoreFakes
import Foundation
import Testing
@testable import EchoCore

/// "Save vocal with backing track" (SPEC § 13.6).
struct TakeMixerTests {
    private func write(_ channels: [[Float]], rate: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels.count))!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count))!
        buffer.frameLength = AVAudioFrameCount(channels[0].count)
        for (index, samples) in channels.enumerated() {
            for frame in samples.indices { buffer.floatChannelData![index][frame] = samples[frame] }
        }
        try file.write(from: buffer)
    }

    @Test func theVoiceMovesEarlierAndTheTrackStartsWhereTheTakeDid() throws {
        let folder = try temporaryFolder()
        let vocal = folder.appending(path: "processed.caf"), backing = folder.appending(path: "backing.wav")
        // The voice: a click 10 ms in (where the singer answered the track's frame 0, 10 ms late), then quiet.
        var voice = [Float](repeating: 0, count: 96_000)
        voice[480] = 1
        try write([voice], rate: 48_000, to: vocal)
        // The track: 44.1 kHz stereo, left 0.2 and right −0.2 after its first second, silence before.
        let left = (0..<132_300).map { $0 < 44_100 ? Float(0) : 0.2 }, right = left.map { -$0 }
        try write([left, right], rate: 44_100, to: backing)

        let output = folder.appending(path: "working.caf")
        try TakeMixer.mix(vocal: vocal, backing: backing, startSeconds: 1, latencySeconds: 0.01, volume: 0.5, to: output)
        let mixed = try readSamples(output)
        #expect(mixed.format.sampleRate == 48_000)
        #expect(mixed.channels.count == 2, "stereo with a stereo track")
        #expect(mixed.channels[0].count == 96_000, "as long as the vocal")
        #expect(abs(mixed.channels[0][0] - (1 + 0.1)) < 0.02, "the click on the track's first frame, plus the track at half volume")
        #expect(abs(mixed.channels[1][0] - (1 - 0.1)) < 0.02)
        #expect(abs(mixed.channels[0][40_000] - 0.1) < 0.002, "the track from 1 s in, at half volume")
        #expect(abs(mixed.channels[1][40_000] + 0.1) < 0.002)
    }

    @Test func aMixProjectEditsTheMixAndKeepsTheVoiceAlone() async throws {
        let root = try temporaryFolder()
        let repository = FileProjectRepository(root: root, migrator: ProjectMigrator(), clock: FakeClock())
        let id = UUID()
        let takes = try await repository.createFolder(for: id).takeFolder
        try FileManager.default.createDirectory(at: takes.url, withIntermediateDirectories: true)
        let voice = (0..<48_000).map { 0.3 * sin(Float($0) * 0.03) }
        for url in [takes.raw, takes.processed] {
            let writer = try CAFWriter(url: url, sampleRate: 48_000, channelCount: 1)
            try voice.withUnsafeBufferPointer { try writer.append([$0.baseAddress!], frames: voice.count) }
            try writer.close()
        }
        try write([[Float](repeating: 0.1, count: 96_000)], rate: 48_000, to: takes.url.appending(path: "backing.caf"))
        let session = TakeSession(
            startedAt: Date(), channelNames: ["Voice"],
            backingTrack: .init(fileName: "backing.caf", displayName: "Song", startSeconds: 0, latencySeconds: 0, volume: 1)
        )
        let builder = RecordedProjectBuilder(repository: repository, inspector: AVMediaInspector())
        let project = try await builder.buildProject(id: id, title: "Mix", session: session, editingSource: .mix)

        #expect(project.recording?.editingSource == .mix)
        #expect(project.recording?.backingTrack?.displayName == "Song")
        let working = try readSamples(repository.folder(for: id).working).channels[0]
        #expect(abs(working[1_000] - (voice[1_000] + 0.1)) < 1e-5, "voice and track together")
        #expect(try readSamples(takes.processed).channels[0] == voice, "the vocal take stays on its own")
    }
}

struct EditingSourceSwitchTests {
    @Test func aRecordingSwitchesBetweenItsTakes() async throws {
        let root = try temporaryFolder()
        let repository = FileProjectRepository(root: root, migrator: ProjectMigrator(), clock: FakeClock())
        let id = UUID()
        let folder = try await repository.createFolder(for: id)
        try FileManager.default.createDirectory(at: folder.takes, withIntermediateDirectories: true)
        for (url, level) in [(folder.takeFolder.raw, Float(0.1)), (folder.takeFolder.processed, Float(0.4))] {
            let writer = try CAFWriter(url: url, sampleRate: 48_000, channelCount: 1)
            let samples = [Float](repeating: level, count: 4_800)
            try samples.withUnsafeBufferPointer { try writer.append([$0.baseAddress!], frames: 4_800) }
            try writer.close()
        }
        try FileManager.default.copyItem(at: folder.takeFolder.processed, to: folder.working)
        let project = Project(
            id: id, title: "Take", mediaType: .audio, origin: .recorded, sourceFileName: "takes/processed.caf",
            sourceInfo: SourceInfo(duration: 0.1, container: "", audioCodec: "lpcm", videoCodec: nil, byteSize: 0, channelCount: 1, sampleRate: 48_000),
            recording: RecordingMetadata(channelNames: ["Voice"]), createdAt: Date()
        )
        let builder = RecordedProjectBuilder(repository: repository, inspector: AVMediaInspector())

        let raw = try await builder.switchEditingSource(of: project, to: .raw)
        #expect(raw.recording?.editingSource == .raw)
        #expect(raw.sourceFileName == "takes/raw.caf")
        #expect(try readSamples(folder.working).channels[0].allSatisfy { $0 == 0.1 })
        #expect(await repository.waveformOverview(id: id)?.max() == 0.1)
        let back = try await builder.switchEditingSource(of: raw, to: .processed)
        #expect(try readSamples(folder.working).channels[0].allSatisfy { $0 == 0.4 })
        #expect(back.recording?.editingSource == .processed)

        var mix = project
        mix.recording?.editingSource = .mix
        await #expect(throws: RecordingError.cantCreateProject) { try await builder.switchEditingSource(of: mix, to: .raw) }
    }
}

struct CacheAndConsentTests {
    @Test func theRenderCacheMeasuresAndClearsEveryProject() async throws {
        let root = try temporaryFolder()
        let cache = FileRenderCache(root: root)
        for project in [UUID(), UUID()] {
            let file = try await cache.temporaryURL(projectID: project)
            try Data(repeating: 1, count: 100_000).write(to: file)
            _ = try await cache.store(file, for: RenderKey(hash: String(repeating: "a", count: 64))!, projectID: project)
        }
        #expect(try await cache.totalBytes() >= 200_000)
        try await cache.removeEverything()
        #expect(try await cache.totalBytes() == 0)
        #expect(FileManager.default.fileExists(atPath: root.path()), "the folder itself stays")
    }

    @MainActor
    @Test func consentIsOffUntilAnsweredAndRemembered() throws {
        let defaults = try #require(UserDefaults(suiteName: "consent-\(UUID().uuidString)"))
        let store = UserDefaultsConsentStore(defaults: defaults)
        #expect(!store.hasAnswered)
        #expect(!store.sharesAnalytics && !store.sharesCrashReports, "nothing is collected before the answer")
        store.recordAnswer(analytics: true, crashReports: false)
        let again = UserDefaultsConsentStore(defaults: defaults)
        #expect(again.hasAnswered)
        #expect(again.sharesAnalytics)
        #expect(!again.sharesCrashReports)
    }
}
