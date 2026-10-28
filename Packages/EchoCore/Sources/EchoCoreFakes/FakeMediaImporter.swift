import EchoCore
import Foundation

/// Reports progress 0.5 then 1 and returns `result`, or throws `error` when set. Writes no files.
public struct FakeMediaImporter: MediaImporting {
    public var result: ImportedMedia
    public var error: (any Error & Sendable)?

    public init(
        result: ImportedMedia = ImportedMedia(sourceFileName: "source.mov", workingChannelCount: 2, overview: []),
        error: (any Error & Sendable)? = nil
    ) {
        self.result = result
        self.error = error
    }

    public func importMedia(
        from source: URL,
        inspection: MediaInspection,
        into folder: ProjectFolder,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ImportedMedia {
        progress(0.5)
        if let error { throw error }
        progress(1)
        return result
    }
}
