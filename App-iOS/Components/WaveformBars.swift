import SwiftUI

/// Vertical bars for levels in 0...1, centred, left to right in every locale (SPEC § 17).
struct WaveformBars: View {
    let levels: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 3) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(height: max(2, geometry.size.height * level))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }

    /// The lowest bar height, so silence still shows as a line of short bars.
    nonisolated static let floor = 0.12

    /// Peak-downsamples `levels` to `count` bars and scales so the loudest bar is full height.
    nonisolated static func bars(from levels: [Float], count: Int) -> [Double] {
        guard !levels.isEmpty, count > 0 else { return [] }
        let peak = Double(levels.max() ?? 0)
        return (0..<count).map { bar in
            let lower = bar * levels.count / count
            let upper = max(lower + 1, (bar + 1) * levels.count / count)
            let level = Double(levels[lower..<upper].max() ?? 0)
            return peak > 0 ? floor + (1 - floor) * level / peak : floor
        }
    }

    /// Stable stand-in bars for projects without a waveform overview (e.g. debug samples).
    nonisolated static func placeholder(seed: UUID, count: Int = 24) -> [Double] {
        let bytes = withUnsafeBytes(of: seed.uuid) { Array($0) }
        return (0..<count).map { index in
            let byte = bytes[index % bytes.count] &+ UInt8(truncatingIfNeeded: index &* 37)
            return 0.3 + Double(byte) / 255 * 0.65
        }
    }
}
