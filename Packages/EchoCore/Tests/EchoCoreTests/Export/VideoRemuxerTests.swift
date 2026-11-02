import AVFoundation
@testable import EchoCore
import Foundation
import Synchronization
import Testing

final class VideoRemuxerTests {
    private let directory: URL

    init() throws {
        directory = try TestMedia.makeDirectory()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The new audio: a 1 kHz stereo tone as AAC, like the export's encoded audio.
    private func newAudio(seconds: Double) async throws -> URL {
        let pcm = directory.appending(path: "render-\(UUID().uuidString).caf")
        let tone = TestSignal.sine(1_000, amplitude: 0.3, frames: Int(seconds * 48_000))
        try TestMedia.writeSamples([tone, tone], to: pcm)
        let aac = directory.appending(path: "audio-\(UUID().uuidString).m4a")
        try await AudioEncoder().encode(pcm, to: aac, settings: .high, progress: { _ in })
        return aac
    }

    private func remux(_ video: URL, audio: URL, trim: TimeRangeCodable, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let output = directory.appending(path: "export-\(UUID().uuidString).\(video.pathExtension)")
        try await VideoRemuxer().remux(video: video, audio: audio, trimRange: trim, to: output, progress: progress)
        return output
    }

    /// The `ftyp` major brand: "qt  " for QuickTime movies.
    private func majorBrand(of url: URL) throws -> String {
        let header = try FileHandle(forReadingFrom: url).read(upToCount: 12) ?? Data()
        return String(decoding: header.suffix(4), as: UTF8.self)
    }

    /// Byte sizes of every compressed sample (frame) of the first track of `type`, in decode order.
    private func sampleSizes(_ url: URL, _ type: AVMediaType) async throws -> [Int] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: type).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var sizes: [Int] = []
        while let buffer = output.copyNextSampleBuffer() {
            // Empty buffers only mark edit boundaries and the end.
            let size = CMSampleBufferGetTotalSampleSize(buffer)
            if size > 0 { sizes.append(size) }
        }
        return sizes
    }

    /// The first audio track decoded to mono float.
    private func decodedAudio(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 48_000,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var data = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: data.count * 4, destination: &data)
            samples += data
        }
        return samples
    }

    @Test(arguments: [AVFileType.mov, .mp4])
    func theContainerStaysTheSame(_ fileType: AVFileType) async throws {
        let video = directory.appending(path: "source.\(fileType == .mov ? "mov" : "mp4")")
        try await TestMedia.writeVideoTrack(to: video, seconds: 2, fileType: fileType)

        let output = try await remux(video, audio: try await newAudio(seconds: 2), trim: .full(duration: 2))

        #expect(VideoRemuxer.fileType(forVideo: video) == fileType)
        #expect(try (majorBrand(of: output) == "qt  ") == (fileType == .mov))
        #expect(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).count == 1)
    }

    @Test func theAudioIsReplacedAndTheVideoCopiedUntouched() async throws {
        let video = directory.appending(path: "with-audio.mov")
        try await TestMedia.writeMovie(to: video, seconds: 2, withAudio: true)

        let output = try await remux(video, audio: try await newAudio(seconds: 2), trim: .full(duration: 2))

        let asset = AVURLAsset(url: output)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(audioTracks.count == 1, "the source's audio is gone")
        let description = try #require(try await audioTracks[0].load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(description) == kAudioFormatMPEG4AAC)
        let audio = try await decodedAudio(output)
        let middle = Array(audio[24_000..<72_000])
        let rising = zip(middle, middle.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        #expect(abs(rising - 1_000) <= 5, "the new 1 kHz audio, not the old 440 Hz")
        #expect(try await sampleSizes(output, .video) == sampleSizes(video, .video), "passthrough: the same compressed frames")
    }

    @Test func trimmingOffAKeyframeKeepsTheFramesAndHidesTheLeadIn() async throws {
        let video = directory.appending(path: "gop.mov")
        try await TestMedia.writeVideoTrack(to: video, seconds: 4, keyframeInterval: 10)
        let trim = TimeRangeCodable(start: 1.5, duration: 1.5)

        let output = try await remux(video, audio: try await newAudio(seconds: 1.5), trim: trim)

        let asset = AVURLAsset(url: output)
        #expect(abs(try await asset.load(.duration).seconds - 1.5) < 0.05)
        let videoTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(abs(try await videoTrack.load(.timeRange).duration.seconds - 1.5) < 0.05)
        let audioTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        #expect(abs(try await audioTrack.load(.timeRange).duration.seconds - 1.5) < 0.05)
        // Frames 15…29 are shown; 10…14 are kept (not re-encoded) for decoding and hidden by an edit list.
        let sizes = try await sampleSizes(output, .video)
        #expect(sizes == Array(try await sampleSizes(video, .video)[10..<30]))
        let segments = try await videoTrack.load(.segments)
        #expect(segments.count == 1)
        #expect(abs((segments.first?.timeMapping.source.start.seconds ?? 0) - 0.5) < 0.01, "the edit starts 0.5 s into the kept frames")
    }

    @Test func orientationColourTagsAndMetadataAreKept() async throws {
        let created = AVMutableMetadataItem()
        created.identifier = .quickTimeMetadataCreationDate
        created.value = "2026-10-30T09:41:00+0000" as NSString
        let location = AVMutableMetadataItem()
        location.identifier = .quickTimeMetadataLocationISO6709
        location.value = "+51.5072-000.1276+011.000/" as NSString
        let rotation = CGAffineTransform(rotationAngle: .pi / 2)
        let video = directory.appending(path: "phone.mov")
        try await TestMedia.writeVideoTrack(to: video, seconds: 2, transform: rotation, hdrColorTags: true, metadata: [created, location])

        let output = try await remux(video, audio: try await newAudio(seconds: 2), trim: .full(duration: 2))

        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        // The file stores the matrix in fixed point; compare with what the source file says.
        let sourceTrack = try #require(try await AVURLAsset(url: video).loadTracks(withMediaType: .video).first)
        let transform = try await track.load(.preferredTransform)
        #expect(transform == (try await sourceTrack.load(.preferredTransform)))
        #expect(abs(transform.b - 1) < 0.001 && abs(transform.c + 1) < 0.001, "rotated 90°")
        let description = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
            == kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
        #expect(CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        let metadata = try await asset.load(.metadata)
        let values = try await metadata.asyncMap { item in (item.identifier, try await item.load(.stringValue)) }
        #expect(values.contains { $0.0 == .quickTimeMetadataCreationDate && $0.1 == "2026-10-30T09:41:00+0000" })
        #expect(values.contains { $0.0 == .quickTimeMetadataLocationISO6709 && $0.1 == "+51.5072-000.1276+011.000/" })
    }

    @Test func progressEndsAtOne() async throws {
        let video = directory.appending(path: "progress.mov")
        try await TestMedia.writeVideoTrack(to: video, seconds: 2)
        let values = Mutex<[Double]>([])

        _ = try await remux(video, audio: try await newAudio(seconds: 2), trim: .full(duration: 2)) { value in
            values.withLock { $0.append(value) }
        }

        let reported = values.withLock { $0 }
        #expect(reported.first == 0)
        #expect(reported.last == 1)
        #expect(zip(reported, reported.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func cancellingLeavesNoFile() async throws {
        let video = directory.appending(path: "cancel.mov")
        try await TestMedia.writeVideoTrack(to: video, seconds: 2)
        let audio = try await newAudio(seconds: 2)
        let output = directory.appending(path: "cancelled.mov")

        let task = Task { try await VideoRemuxer().remux(video: video, audio: audio, trimRange: .full(duration: 2), to: output, progress: { _ in }) }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: output.path()))
    }

    @Test func aSourceWithoutVideoFails() async throws {
        let voice = directory.appending(path: "voice.m4a")
        try TestMedia.writeTone(to: voice, seconds: 1, channels: 1, aac: true)
        let audioOnly = directory.appending(path: "voice.mov")
        try FileManager.default.moveItem(at: voice, to: audioOnly)
        let output = directory.appending(path: "never.mov")

        await #expect(throws: ExportError.unreadableVideo) {
            try await VideoRemuxer().remux(video: audioOnly, audio: try await self.newAudio(seconds: 1), trimRange: .full(duration: 1), to: output, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: output.path()))
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self { results.append(try await transform(element)) }
        return results
    }
}
