import Foundation

/// A loaded backing track (SPEC § 13.6).
public struct BackingTrackInfo: Equatable, Sendable {
    public let url: URL
    /// Seconds.
    public let duration: Double

    public init(url: URL, duration: Double) {
        self.url = url
        self.duration = duration
    }
}
