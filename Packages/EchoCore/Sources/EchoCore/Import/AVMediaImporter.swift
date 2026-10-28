import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Imports with chunked copying and AVAssetReader extraction (SPEC § 6.2, § 10).
public struct AVMediaImporter: MediaImporting {
    public static let workingSampleRate: Double = 48_000
    public static let overviewBucketCount = 48
    static let copyChunkSize = 4 << 20
    static let thumbnailMaxPixelSize: CGFloat = 480

    public init() {}

    public func importMedia(
        from source: URL,
        inspection: MediaInspection,
        into folder: ProjectFolder,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ImportedMedia {
        let sourceFileName = "source.\(inspection.fileExtension)"
        let copy = folder.source(fileName: sourceFileName)
        let written = [copy, folder.working, folder.waveformOverview, folder.thumbnail]
        do {
            try Task.checkCancellation()
            try await Self.copy(source, to: copy, byteCount: inspection.sourceInfo.byteSize) { progress($0 * 0.5) }
            let channels = min(max(inspection.sourceInfo.channelCount, 1), 2)
            let overview = try await Self.extractWorkingAudio(
                from: copy, to: folder.working, channels: channels, duration: inspection.sourceInfo.duration
            ) { progress(0.5 + $0 * 0.5) }
            try JSONEncoder().encode(overview).write(to: folder.waveformOverview, options: .atomic)
            if inspection.mediaType == .video {
                try await Self.writeThumbnail(of: copy, at: inspection.sourceInfo.duration * 0.1, to: folder.thumbnail)
            }
            progress(1)
            return ImportedMedia(sourceFileName: sourceFileName, workingChannelCount: channels, overview: overview)
        } catch {
            let fileManager = FileManager()
            for file in written {
                try? fileManager.removeItem(at: file)
            }
            throw error
        }
    }

    private static func copy(
        _ source: URL,
        to destination: URL,
        byteCount: Int64,
        progress: (Double) -> Void
    ) async throws {
        let isScoped = source.startAccessingSecurityScopedResource()
        defer { if isScoped { source.stopAccessingSecurityScopedResource() } }

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try Data().write(to: destination)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var copied: Int64 = 0
        while let chunk = try input.read(upToCount: copyChunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
            copied += Int64(chunk.count)
            progress(byteCount > 0 ? min(1, Double(copied) / Double(byteCount)) : 0)
            await Task.yield()
        }
    }

    /// Writes 48 kHz 32-bit float CAF with `channels` channels and returns the overview levels.
    private static func extractWorkingAudio(
        from source: URL,
        to destination: URL,
        channels: Int,
        duration: Double,
        progress: (Double) -> Void
    ) async throws -> [Float] {
        let asset = AVURLAsset(url: source)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset),
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: workingSampleRate,
                  channels: AVAudioChannelCount(channels), interleaved: true
              )
        else { throw ImportError.unreadable }

        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: workingSampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        reader.add(output)
        guard reader.startReading() else { throw ImportError.unreadable }
        defer { reader.cancelReading() }

        let file = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        let expectedFrames = max(1, duration * workingSampleRate)
        var overview = [Float](repeating: 0, count: overviewBucketCount)
        var framesWritten = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frameCount > 0 else { continue }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
                throw ImportError.unreadable
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(frameCount), into: buffer.mutableAudioBufferList
            )
            guard status == noErr, let samples = buffer.floatChannelData?[0] else { throw ImportError.unreadable }
            try file.write(from: buffer)

            for frame in 0..<frameCount {
                let bucket = min(overviewBucketCount - 1, Int(Double(framesWritten + frame) / expectedFrames * Double(overviewBucketCount)))
                for channel in 0..<channels {
                    overview[bucket] = max(overview[bucket], min(1, abs(samples[frame * channels + channel])))
                }
            }
            framesWritten += frameCount
            progress(min(1, Double(framesWritten) / expectedFrames))
            await Task.yield()
        }
        guard reader.status == .completed, framesWritten > 0 else { throw ImportError.unreadable }
        return overview
    }

    private static func writeThumbnail(of video: URL, at seconds: Double, to destination: URL) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailMaxPixelSize, height: thumbnailMaxPixelSize)
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        guard let jpeg = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImportError.unreadable
        }
        CGImageDestinationAddImage(jpeg, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(jpeg) else { throw ImportError.unreadable }
    }
}
