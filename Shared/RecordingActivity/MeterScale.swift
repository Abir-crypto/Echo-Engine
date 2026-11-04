import Foundation

/// The level meters' scale (SPEC § 18.5): 30 segments from −60 dBFS to full scale, the last 4 in the clip color.
/// Shared by the Record screen and the Live Activity.
enum MeterScale {
    static let segmentCount = 30
    static let clipSegmentCount = 4
    /// The quietest level that lights a segment.
    static let floorDB: Double = -60

    /// Where a peak (1 = full scale) sits on the meter, 0…1.
    static func fraction(forPeak peak: Float) -> Double {
        guard peak > 0, peak.isFinite else { return 0 }
        let db = 20 * log10(Double(peak))
        return min(1, max(0, 1 - db / floorDB))
    }

    /// Segments lit for a meter position.
    static func litSegments(_ fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        return Int((min(1, max(0, fraction)) * Double(segmentCount)).rounded())
    }

    /// Whether a segment (0-based) shows clipping when lit.
    static func isClipSegment(_ index: Int) -> Bool {
        index >= segmentCount - clipSegmentCount
    }
}
