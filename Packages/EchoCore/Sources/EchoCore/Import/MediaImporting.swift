import Foundation

/// Copies an import into its project folder and prepares it for editing (SPEC § 4.3, § 10).
public protocol MediaImporting: Sendable {
    /// Copies `source` to `source.<ext>`, extracts `working.caf`, and writes the waveform overview and, for
    /// video, `thumbnail.jpg`. `progress` reports 0...1 across copy and extraction. On cancellation
    /// (`CancellationError`) or failure, every file it wrote is removed; the caller removes the folder.
    func importMedia(
        from source: URL,
        inspection: MediaInspection,
        into folder: ProjectFolder,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ImportedMedia
}

public struct ImportedMedia: Equatable, Sendable {
    /// `source.<ext>`, for `Project.sourceFileName`.
    public var sourceFileName: String
    /// 1 or 2: sources with more channels are downmixed to stereo (SPEC § 6.2).
    public var workingChannelCount: Int
    /// Peak level per bucket (0...1) across the whole source, for Home card bars.
    public var overview: [Float]

    public init(sourceFileName: String, workingChannelCount: Int, overview: [Float]) {
        self.sourceFileName = sourceFileName
        self.workingChannelCount = workingChannelCount
        self.overview = overview
    }
}
