import Foundation

/// Keeps the chosen backing track (SPEC § 13.6): a copy in the app's storage, so it stays when the original moves, and a
/// copy in each take sung over it, for mixing.
public protocol BackingTrackStoring: Sendable {
    /// The folder the stored copies live in.
    var root: URL { get }
    /// Copies the chosen file (a security-scoped URL from Files) in under a new name; returns the copy.
    func store(_ url: URL) throws -> URL
    func remove(fileName: String)
    /// Copies a stored track into the take's folder as `backing.<ext>`; returns that file name.
    func copy(_ url: URL, into folder: TakeFolder) throws -> String
}

public struct FileBackingTrackStore: BackingTrackStoring {
    public let root: URL

    /// `root`: e.g. `Application Support/BackingTracks`.
    public init(root: URL) {
        self.root = root
    }

    public func store(_ url: URL) throws -> URL {
        let files = FileManager()
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let copy = root.appending(path: "\(UUID().uuidString).\(url.pathExtension.lowercased())")
        try files.copyItem(at: url, to: copy)
        return copy
    }

    public func remove(fileName: String) {
        try? FileManager().removeItem(at: root.appending(path: fileName))
    }

    public func copy(_ url: URL, into folder: TakeFolder) throws -> String {
        let files = FileManager()
        let name = "backing.\(url.pathExtension.lowercased())"
        try files.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let destination = folder.url.appending(path: name)
        if files.fileExists(atPath: destination.path(percentEncoded: false)) { try files.removeItem(at: destination) }
        try files.copyItem(at: url, to: destination)
        return name
    }
}

extension URL {
    /// `Application Support/BackingTracks`: the chosen backing track (SPEC § 13.6).
    public static var backingTracksDirectory: URL {
        .applicationSupportDirectory.appending(path: "BackingTracks", directoryHint: .isDirectory)
    }
}
