import EchoCore
import Foundation

/// Always returns `now`.
public struct FakeClock: DateProviding {
    public var now: Date

    public init(now: Date = Date(timeIntervalSince1970: 1_793_000_000)) {
        self.now = now
    }
}
