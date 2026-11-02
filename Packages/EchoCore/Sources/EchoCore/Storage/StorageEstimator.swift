import Foundation

/// The SPEC § 15 estimates. KB = 1,000 bytes, matching the decimal sizes the app shows.
public struct StorageEstimator: StorageEstimating {
    /// Working audio: 48 kHz 32-bit float stereo.
    public static let workingAudioBytesPerSecond: Int64 = 384_000
    /// Lossless render: ALAC stereo 48 kHz.
    public static let renderBytesPerSecond: Int64 = 100_000
    /// Encoded export audio: AAC 256 kbps.
    public static let encodedAudioBytesPerSecond: Int64 = 32_000
    public static let margin: Int64 = 200_000_000
    public static let exportMargin: Int64 = 100_000_000

    private let volume: URL

    /// `volume` is any URL on the volume that holds the projects.
    public init(volume: URL) {
        self.volume = volume
    }

    public func bytesToImport(_ source: SourceInfo) -> Int64 {
        source.byteSize + Self.bytes(source.duration, at: Self.workingAudioBytesPerSecond) + Self.margin
    }

    public func bytesToEdit(_ project: Project) -> Int64 {
        Self.bytes(project.sourceInfo.duration, at: Self.renderBytesPerSecond) * 2 + Self.margin
    }

    public func bytesToExport(_ project: Project) -> Int64 {
        let aac256 = Self.encodedAudioBytesPerSecond * 8
        let output: ExportOutput = project.mediaType == .video
            ? .video(audioBitrate: Int(aac256))
            : .audioOnly(AudioExportSettings(format: .aac, sampleRate: 48_000, bitDepth: nil, bitrate: Int(aac256)))
        return bytesToExport(project, output: output)
    }

    /// The lossless render, each encoded audio (the video's AAC, the audio file), the trimmed video and a margin.
    public func bytesToExport(_ project: Project, output: ExportOutput) -> Int64 {
        let trimmed = project.trimRange.duration
        var bytesPerSecond = Self.renderBytesPerSecond
        if let bitrate = output.videoAudioBitrate { bytesPerSecond += Int64(bitrate / 8) }
        if let settings = output.audioSettings { bytesPerSecond += Self.encodedBytesPerSecond(settings) }
        var bytes = Self.bytes(trimmed, at: bytesPerSecond) + Self.exportMargin
        if output.includesVideo, project.mediaType == .video, project.sourceInfo.duration > 0 {
            let trimRatio = min(1, trimmed / project.sourceInfo.duration)
            bytes += Int64((Double(project.sourceInfo.byteSize) * trimRatio).rounded(.up))
        }
        return bytes
    }

    public func availableBytes() throws -> Int64 {
        let values = try volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Stereo is assumed, as for renders. FLAC and ALAC are taken as large as the ALAC render at their rate and depth.
    private static func encodedBytesPerSecond(_ settings: AudioExportSettings) -> Int64 {
        let bitDepth = Double(settings.bitDepth ?? 24)
        switch settings.format {
        case .aac:
            return Int64((settings.bitrate ?? 256_000) / 8)
        case .wav:
            return Int64((settings.sampleRate * 2 * bitDepth / 8).rounded(.up))
        case .flac, .alac:
            return Int64((Double(renderBytesPerSecond) * settings.sampleRate / 48_000 * bitDepth / 24).rounded(.up))
        }
    }

    private static func bytes(_ seconds: Double, at bytesPerSecond: Int64) -> Int64 {
        Int64((seconds * Double(bytesPerSecond)).rounded(.up))
    }
}
