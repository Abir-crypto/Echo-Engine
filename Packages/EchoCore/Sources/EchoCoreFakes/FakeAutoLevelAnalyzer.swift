import EchoCore
import Foundation

/// Returns `gain` and records each request.
public actor FakeAutoLevelAnalyzer: AutoLevelAnalyzing {
    public struct Request: Sendable {
        public let audio: URL
        public let manual: ManualSettings
        public let range: TimeRangeCodable
        public let target: LoudnessTarget
    }

    public var gain: Double
    public private(set) var requests: [Request] = []

    public init(gain: Double = 4) {
        self.gain = gain
    }

    public func gain(
        of audio: URL, manual: ManualSettings, range: TimeRangeCodable, target: LoudnessTarget, progress: @Sendable (Double) -> Void
    ) async throws -> Double {
        requests.append(Request(audio: audio, manual: manual, range: range, target: target))
        progress(0)
        progress(1)
        return gain
    }
}
