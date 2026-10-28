/// A time range in seconds, relative to the start of the source media.
public struct TimeRangeCodable: Codable, Equatable, Hashable, Sendable {
    public var start: Double
    public var duration: Double

    public init(start: Double, duration: Double) {
        self.start = start
        self.duration = duration
    }

    public var end: Double { start + duration }

    /// The whole source, from zero to `duration`.
    public static func full(duration: Double) -> TimeRangeCodable {
        TimeRangeCodable(start: 0, duration: duration)
    }
}
