import EchoCore
import Foundation

/// Returns `peaks` for every file; generates and caches nothing, and records cache removals.
public actor FakeWaveformProvider: WaveformProviding {
    public let peaks: WaveformPeaks
    public private(set) var removedProjectIDs: [UUID] = []
    public private(set) var removedKeys: Set<String> = []

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

    public func remove(keys: Set<String>, projectID: UUID) {
        removedKeys.formUnion(keys)
    }

    public private(set) var bytes: Int64 = 0
    public private(set) var removedEverythingCount = 0

    public func setBytes(_ bytes: Int64) {
        self.bytes = bytes
    }

    public func totalBytes() -> Int64 { bytes }

    public func removeEverything() {
        bytes = 0
        removedEverythingCount += 1
    }

    public func removeAll(projectID: UUID) {
        removedProjectIDs.append(projectID)
    }
}
