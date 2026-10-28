import AVFoundation
import Foundation
import Testing

/// Generates small real media files for import tests.
enum TestMedia {
    static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TestMedia-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A 440 Hz tone. The file type follows the extension; `aac` encodes AAC (use `.m4a`), otherwise 16-bit PCM.
    static func writeTone(to url: URL, seconds: Double, channels: Int, sampleRate: Double = 48_000, aac: Bool = false) throws {
        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        if aac {
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = 128_000
        } else {
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = url.pathExtension.lowercased().hasPrefix("aif")
        }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<channels {
            let samples = try #require(buffer.floatChannelData?[channel])
            for frame in 0..<Int(frames) {
                samples[frame] = 0.25 * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
            }
        }
        try file.write(from: buffer)
    }

    /// A 64×64 H.264 QuickTime movie, with an AAC stereo track when `withAudio`.
    static func writeMovie(to url: URL, seconds: Double, withAudio: Bool) async throws {
        let videoOnly = withAudio ? url.deletingLastPathComponent().appending(path: "video-only-\(UUID().uuidString).mov") : url
        try await writeVideoTrack(to: videoOnly, seconds: seconds)
        guard withAudio else { return }

        let audio = url.deletingLastPathComponent().appending(path: "audio-\(UUID().uuidString).m4a")
        try writeTone(to: audio, seconds: seconds, channels: 2, aac: true)
        let composition = AVMutableComposition()
        for (source, type) in [(videoOnly, AVMediaType.video), (audio, .audio)] {
            let asset = AVURLAsset(url: source)
            let track = try #require(try await asset.loadTracks(withMediaType: type).first)
            let range = try await track.load(.timeRange)
            let target = try #require(composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid))
            try target.insertTimeRange(range, of: track, at: .zero)
        }
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: url, as: .mov)
    }

    private static func writeVideoTrack(to url: URL, seconds: Double) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let framesPerSecond: Int32 = 10
        for frame in 0..<Int(seconds * Double(framesPerSecond)) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            let pool = try #require(adaptor.pixelBufferPool)
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            adaptor.append(try #require(pixelBuffer), withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: framesPerSecond))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}
