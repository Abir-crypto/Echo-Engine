import EchoCore
import Foundation

/// Returns `measurement` for every file and records each request.
public actor FakeLoudnessAnalyzer: LoudnessAnalyzing {
    public var measurement: LoudnessMeasurement
    public private(set) var requests: [(audio: URL, range: TimeRangeCodable)] = []

    public init(measurement: LoudnessMeasurement = LoudnessMeasurement(integratedLUFS: -23, truePeakDBTP: -3)) {
        self.measurement = measurement
    }

    public func setMeasurement(_ measurement: LoudnessMeasurement) { self.measurement = measurement }

    public func measure(_ audio: URL, range: TimeRangeCodable, progress: @Sendable (Double) -> Void) async throws -> LoudnessMeasurement {
        requests.append((audio, range))
        progress(1)
        return measurement
    }
}
