import AVFoundation
import CEchoDSP

/// Integrated loudness and true peak of a file range (SPEC § 4.3, § 6.7).
public protocol LoudnessAnalyzing: Sendable {
    func measure(_ audio: URL, range: TimeRangeCodable, progress: @Sendable (Double) -> Void) async throws -> LoudnessMeasurement
}

public struct LoudnessMeasurement: Equatable, Sendable {
    /// LUFS; `nil` when nothing passes the gates (silence).
    public let integratedLUFS: Double?
    /// dBTP; −infinity for digital silence.
    public let truePeakDBTP: Double

    public init(integratedLUFS: Double?, truePeakDBTP: Double) {
        self.integratedLUFS = integratedLUFS
        self.truePeakDBTP = truePeakDBTP
    }
}

public enum LoudnessError: Error, Equatable {
    case unreadable
}

/// ITU-R BS.1770-4 / EBU R128 measurement of a file (any sample rate, mono or stereo), via `LoudnessMeter` in
/// `CEchoDSP`. Reads one second at a time, reporting progress and stopping when cancelled.
public struct EBUR128Analyzer: LoudnessAnalyzing {
    public init() {}

    public func measure(_ audio: URL, range: TimeRangeCodable, progress: @Sendable (Double) -> Void) async throws -> LoudnessMeasurement {
        try await LoudnessScan.measure(audio, range: range, measuresTruePeak: true, progress: progress)
    }
}
