import EchoCore
import Foundation
import Testing

final class AVMediaInspectorTests {
    private let directory: URL
    private let inspector = AVMediaInspector()

    init() throws {
        directory = try TestMedia.makeDirectory()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func wavIsAudioWithItsFormatDetails() async throws {
        let url = directory.appending(path: "voice.wav")
        try TestMedia.writeTone(to: url, seconds: 2, channels: 1)

        let inspection = try await inspector.inspect(url)

        #expect(inspection.mediaType == .audio)
        #expect(inspection.fileExtension == "wav")
        #expect(abs(inspection.sourceInfo.duration - 2) < 0.01)
        #expect(inspection.sourceInfo.channelCount == 1)
        #expect(inspection.sourceInfo.sampleRate == 48_000)
        #expect(inspection.sourceInfo.audioCodec == "lpcm")
        #expect(inspection.sourceInfo.videoCodec == nil)
        #expect(inspection.sourceInfo.container == "com.microsoft.waveform-audio")
        #expect(inspection.sourceInfo.byteSize > 190_000)
    }

    @Test func aacInM4AIsStereoAudio() async throws {
        let url = directory.appending(path: "song.m4a")
        try TestMedia.writeTone(to: url, seconds: 1, channels: 2, aac: true)

        let inspection = try await inspector.inspect(url)

        #expect(inspection.mediaType == .audio)
        #expect(inspection.sourceInfo.audioCodec == "aac ")
        #expect(inspection.sourceInfo.channelCount == 2)
        #expect(inspection.sourceInfo.container == "com.apple.m4a-audio")
    }

    @Test(arguments: ["caf", "aiff"])
    func otherPCMContainersAreAudio(_ fileExtension: String) async throws {
        let url = directory.appending(path: "take.\(fileExtension)")
        try TestMedia.writeTone(to: url, seconds: 1, channels: 2)

        let inspection = try await inspector.inspect(url)

        #expect(inspection.mediaType == .audio)
        #expect(inspection.fileExtension == fileExtension)
    }

    @Test func extensionIsMatchedCaseInsensitively() async throws {
        let url = directory.appending(path: "TAKE.WAV")
        try TestMedia.writeTone(to: url, seconds: 1, channels: 1)

        #expect(try await inspector.inspect(url).fileExtension == "wav")
    }

    @Test func movieWithAudioIsVideo() async throws {
        let url = directory.appending(path: "vlog.mov")
        try await TestMedia.writeMovie(to: url, seconds: 1, withAudio: true)

        let inspection = try await inspector.inspect(url)

        #expect(inspection.mediaType == .video)
        #expect(inspection.sourceInfo.videoCodec == "avc1")
        #expect(inspection.sourceInfo.audioCodec == "aac ")
        #expect(inspection.sourceInfo.container == "com.apple.quicktime-movie")
    }

    @Test func movieWithoutAudioIsRejected() async throws {
        let url = directory.appending(path: "silent.mov")
        try await TestMedia.writeMovie(to: url, seconds: 1, withAudio: false)

        await #expect(throws: ImportError.noAudio) { try await inspector.inspect(url) }
    }

    @Test(arguments: ["mkv", "webm", "avi", "ogg", "txt", ""])
    func unsupportedFormatsAreRejected(_ fileExtension: String) async throws {
        let url = directory.appending(path: fileExtension.isEmpty ? "noextension" : "clip.\(fileExtension)")
        try Data("not media".utf8).write(to: url)

        await #expect(throws: ImportError.unsupportedFormat) { try await inspector.inspect(url) }
    }

    @Test func supportedNameWithBrokenContentsIsUnreadable() async throws {
        let url = directory.appending(path: "broken.mp3")
        try Data("not really an mp3".utf8).write(to: url)

        await #expect(throws: ImportError.unreadable) { try await inspector.inspect(url) }
    }
}
