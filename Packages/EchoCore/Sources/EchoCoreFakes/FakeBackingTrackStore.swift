import EchoCore
import Foundation

/// Stores nothing: `store` hands back a URL in `root` and remembers the calls; `copy` names `backing.<ext>`.
public final class FakeBackingTrackStore: BackingTrackStoring, @unchecked Sendable {
    public let root = URL(filePath: "/fake/BackingTracks")
    public private(set) var stored: [URL] = []
    public private(set) var removed: [String] = []
    public private(set) var copiedInto: [TakeFolder] = []
    public var error: (any Error)?

    public init() {}

    public func store(_ url: URL) throws -> URL {
        if let error { throw error }
        stored.append(url)
        return root.appending(path: "stored-\(stored.count).\(url.pathExtension)")
    }

    public func remove(fileName: String) {
        removed.append(fileName)
    }

    public func copy(_ url: URL, into folder: TakeFolder) throws -> String {
        if let error { throw error }
        copiedInto.append(folder)
        return "backing.\(url.pathExtension)"
    }
}
