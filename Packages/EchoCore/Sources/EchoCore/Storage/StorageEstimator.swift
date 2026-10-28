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
        let trimmed = project.trimRange.duration
        var bytes = Self.bytes(trimmed, at: Self.renderBytesPerSecond + Self.encodedAudioBytesPerSecond) + Self.exportMargin
        if project.mediaType == .video, project.sourceInfo.duration > 0 {
            let trimRatio = min(1, trimmed / project.sourceInfo.duration)
            bytes += Int64((Double(project.sourceInfo.byteSize) * trimRatio).rounded(.up))
        }
        return bytes
    }

    public func availableBytes() throws -> Int64 {
        let values = try volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    private static func bytes(_ seconds: Double, at bytesPerSecond: Int64) -> Int64 {
        Int64((seconds * Double(bytesPerSecond)).rounded(.up))
    }
}
