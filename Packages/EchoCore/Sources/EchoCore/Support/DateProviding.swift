import Foundation

/// Testable time (SPEC § 4.3).
public protocol DateProviding: Sendable {
    var now: Date { get }
}

public struct SystemClock: DateProviding {
    public init() {}

    public var now: Date { Date() }
}
