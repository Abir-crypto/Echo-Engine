import EchoCore
import Foundation

/// Returns `peaks` for every file; generates and caches nothing.
public struct FakeWaveformProvider: WaveformProviding {
    public var peaks: WaveformPeaks

    public init(peaks: WaveformPeaks = WaveformPeaks(sampleRate: 48_000, sourceFrameCount: 0, peaks: [])) {
        self.peaks = peaks
    }

    public func peaks(
        of audio: URL,
        projectID: UUID,
        key: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> WaveformPeaks {
        peaks
    }

    public func removeAll(projectID: UUID) {}
}
