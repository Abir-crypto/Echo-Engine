import Foundation

/// Reads what an import candidate contains: duration, tracks, container, codecs, size (SPEC § 4.3, § 10).
public protocol MediaInspecting: Sendable {
    /// Throws `ImportError.unsupportedFormat`, `.noAudio` or `.unreadable`.
    func inspect(_ url: URL) async throws -> MediaInspection
}

public struct MediaInspection: Equatable, Sendable {
    /// `.video` when the file has a video track, otherwise `.audio`.
    public var mediaType: MediaType
    public var sourceInfo: SourceInfo
    /// Lowercased, e.g. `mov`; the import copies the file to `source.<ext>`.
    public var fileExtension: String

    public init(mediaType: MediaType, sourceInfo: SourceInfo, fileExtension: String) {
        self.mediaType = mediaType
        self.sourceInfo = sourceInfo
        self.fileExtension = fileExtension
    }
}

/// Why an import can't go ahead (SPEC § 4.7, § 10).
public enum ImportError: Error, Equatable {
    /// Not one of the supported containers, e.g. MKV or WebM.
    case unsupportedFormat
    /// A video without an audio track.
    case noAudio
    /// The file is supported by name but its contents can't be read.
    case unreadable
}
