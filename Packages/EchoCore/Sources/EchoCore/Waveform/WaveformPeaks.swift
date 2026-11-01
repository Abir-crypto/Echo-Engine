import Foundation

/// Peak magnitudes of an audio file at multiple resolutions, for the overview strip and the zoomable detail
/// waveform (SPEC § 9).
///
/// The base level holds the largest absolute sample (any channel) per `framesPerBucket` frames; each coarser level
/// halves the previous one by taking pairwise maxima, so a query for any range and bar count reads few values.
public struct WaveformPeaks: Equatable, Sendable {
    /// ≈ 5.3 ms at 48 kHz.
    public static let framesPerBucket = 256

    public let sampleRate: Double
    /// Frames in the source file; used to tell whether a cached copy still matches it.
    public let sourceFrameCount: Int64
    /// Base-level peaks, 0...1 for normal audio.
    public let peaks: [Float]
    /// `levels[0] == peaks`; `levels[k]` covers `2^k` base buckets per value.
    private let levels: [[Float]]

    public init(sampleRate: Double, sourceFrameCount: Int64, peaks: [Float]) {
        self.sampleRate = sampleRate
        self.sourceFrameCount = sourceFrameCount
        self.peaks = peaks
        var levels = [peaks]
        while let last = levels.last, last.count > 1 {
            levels.append(stride(from: 0, to: last.count, by: 2).map { index in
                index + 1 < last.count ? max(last[index], last[index + 1]) : last[index]
            })
        }
        self.levels = levels
    }

    public static func == (lhs: WaveformPeaks, rhs: WaveformPeaks) -> Bool {
        lhs.sampleRate == rhs.sampleRate && lhs.sourceFrameCount == rhs.sourceFrameCount && lhs.peaks == rhs.peaks
    }

    /// Seconds covered by the source.
    public var duration: Double {
        sampleRate > 0 ? Double(sourceFrameCount) / sampleRate : 0
    }

    /// `count` peaks evenly covering `start..<end` seconds. Each value is the largest peak in its slice (rounded
    /// outward to the level used, so a peak is never missed); time outside the source reads as 0.
    public func levels(from start: Double, to end: Double, count: Int) -> [Float] {
        guard count > 0, end > start, sampleRate > 0, !peaks.isEmpty else {
            return Array(repeating: 0, count: max(count, 0))
        }
        let bucketsPerSecond = sampleRate / Double(Self.framesPerBucket)
        let firstBucket = start * bucketsPerSecond
        let bucketsPerValue = (end - start) * bucketsPerSecond / Double(count)
        let level = min(levels.count - 1, max(0, Int(log2(max(bucketsPerValue, 1)).rounded(.down))))
        let values = levels[level]
        let scale = Double(1 << level)

        return (0..<count).map { index in
            let lower = (firstBucket + Double(index) * bucketsPerValue) / scale
            let upper = (firstBucket + Double(index + 1) * bucketsPerValue) / scale
            let first = Int(lower.rounded(.down))
            let last = max(first + 1, Int(upper.rounded(.up)))
            let clampedFirst = max(first, 0), clampedLast = min(last, values.count)
            guard clampedFirst < clampedLast else { return 0 }
            return values[clampedFirst..<clampedLast].max() ?? 0
        }
    }
}
