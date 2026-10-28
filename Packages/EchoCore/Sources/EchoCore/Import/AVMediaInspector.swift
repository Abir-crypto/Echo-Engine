import AVFoundation
import UniformTypeIdentifiers

/// Inspects media with AVFoundation (SPEC § 10).
public struct AVMediaInspector: MediaInspecting {
    /// Supported containers: video MOV, MP4, M4V; audio M4A/AAC, MP3, WAV, AIFF, CAF, FLAC (SPEC § 10).
    static let supportedTypes: [UTType] = [
        .quickTimeMovie, .mpeg4Movie, UTType("com.apple.m4v-video"),
        .mpeg4Audio, UTType("public.aac-audio"), .mp3, .wav, .aiff, UTType("public.aifc-audio"),
        UTType("com.apple.coreaudio-format"), UTType("org.xiph.flac"),
    ].compactMap { $0 }

    public init() {}

    public func inspect(_ url: URL) async throws -> MediaInspection {
        let fileExtension = url.pathExtension.lowercased()
        guard let type = UTType(filenameExtension: fileExtension),
              Self.supportedTypes.contains(where: { type.conforms(to: $0) })
        else { throw ImportError.unsupportedFormat }

        let asset = AVURLAsset(url: url)
        let duration: CMTime
        let audioTracks: [AVAssetTrack]
        let videoTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw ImportError.unreadable
        }

        let mediaType: MediaType = videoTracks.isEmpty ? .audio : .video
        guard let audioTrack = audioTracks.first else {
            throw mediaType == .video ? ImportError.noAudio : ImportError.unreadable
        }
        guard let audioFormat = try? await audioTrack.load(.formatDescriptions).first,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee,
              duration.isNumeric
        else { throw ImportError.unreadable }
        let videoFormat = try? await videoTracks.first?.load(.formatDescriptions).first
        let byteSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }

        let sourceInfo = SourceInfo(
            duration: duration.seconds,
            container: type.identifier,
            audioCodec: Self.fourCharacterCode(CMFormatDescriptionGetMediaSubType(audioFormat)),
            videoCodec: videoFormat.map { Self.fourCharacterCode(CMFormatDescriptionGetMediaSubType($0)) },
            byteSize: Int64(byteSize ?? 0),
            channelCount: Int(stream.mChannelsPerFrame),
            sampleRate: stream.mSampleRate
        )
        return MediaInspection(mediaType: mediaType, sourceInfo: sourceInfo, fileExtension: fileExtension)
    }

    /// `kAudioFormatMPEG4AAC` → `"aac "`.
    private static func fourCharacterCode(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
