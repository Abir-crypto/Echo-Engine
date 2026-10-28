import Foundation

extension URL {
    /// `Documents/Projects`: one folder per project, named by its UUID (SPEC § 5.1).
    public static var projectsDirectory: URL {
        .documentsDirectory.appending(path: "Projects", directoryHint: .isDirectory)
    }
}

/// The files of one project folder (SPEC § 5.1).
public struct ProjectFolder: Equatable, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `project.json`, the Codable manifest.
    public var manifest: URL { url.appending(path: "project.json") }
    /// The imported original, never modified, e.g. `source.mov`.
    public func source(fileName: String) -> URL { url.appending(path: fileName) }
    /// Extracted working audio, 48 kHz float.
    public var working: URL { url.appending(path: "working.caf") }
    /// Recording takes: `raw.caf`, `processed.caf`, `ch1.caf`…
    public var takes: URL { url.appending(path: "takes", directoryHint: .isDirectory) }
    /// Video frame at 10% of the source; video projects only.
    public var thumbnail: URL { url.appending(path: "thumbnail.jpg") }
    /// JSON array of peak levels (0...1) across the source, drawn as tinted bars on Home cards.
    public var waveformOverview: URL { url.appending(path: "waveform-overview.json") }
}
