import Foundation

/// The files of a project's `takes/` folder (SPEC § 5.1, § 13.3).
public struct TakeFolder: Equatable, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The unprocessed mixdown.
    public var raw: URL { url.appending(path: "raw.caf") }
    /// The mixdown with live processing.
    public var processed: URL { url.appending(path: "processed.caf") }
    /// One selected channel, unprocessed: `ch1.caf` is the first channel in take order.
    public func channel(_ number: Int) -> URL { url.appending(path: "ch\(number).caf") }
    /// `TakeSession`: present while the take is unfinished.
    public var session: URL { url.appending(path: "session.json") }
}

extension ProjectFolder {
    /// The project's recording takes.
    public var takeFolder: TakeFolder { TakeFolder(url: takes) }
}
