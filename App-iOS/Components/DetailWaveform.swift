import EchoCore
import SwiftUI

/// The audio project header: the waveform around the playhead, the original (grey) behind the processed audio
/// (tint). Pinch to zoom, drag to scrub. Always left to right (SPEC § 9, § 17).
struct DetailWaveform: View {
    let original: WaveformPeaks?
    /// `nil` when the project has no processing: the original is drawn as unprocessed audio.
    let processed: WaveformPeaks?
    /// Waveforms are drawn relative to this peak.
    let peakLevel: Float
    let currentTime: Double
    let duration: Double
    @Binding var visibleDuration: Double
    let onScrub: (Double) -> Void

    @Environment(\.appTint) private var tint
    @State private var zoomStart: Double?
    @State private var scrubStart: Double?

    private static let barWidth: CGFloat = 5
    private static let barGap: CGFloat = 3
    /// The closest zoom shows this many seconds.
    static let minimumVisibleDuration: Double = 2

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .gesture(scrub(width: geometry.size.width))
        }
        .overlay {
            Rectangle()
                .fill(.token(.playhead))
                .frame(width: 2)
        }
        .overlay(alignment: .top) {
            Text(DisplayFormat.duration(currentTime))
                .font(.caption.bold())
                .monospacedDigit()
                .foregroundStyle(.token(.ground))
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(.token(.textPrimary), in: .rect(cornerRadius: 8))
                .padding(.top, 10)
        }
        .overlay(alignment: .bottomLeading) {
            Text("Pinch to zoom")
                .font(.caption)
                .foregroundStyle(.token(.textSecondary))
                .padding(12)
        }
        // The time bubble and caption sit inside a fixed 200 pt well.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .frame(height: 200)
        // Waveform wells are 12 (SPEC § 18.4; the mockup's 16 is overridden by SPEC).
        .background(.token(.surface), in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
        .simultaneousGesture(zoom)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement()
        .accessibilityLabel(Text("Waveform"))
        .accessibilityValue(Text(DisplayFormat.duration(currentTime)))
        .accessibilityAdjustableAction { direction in
            onScrub(currentTime + (direction == .increment ? 5 : -5))
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let count = max(1, Int(size.width / (Self.barWidth + Self.barGap)))
        let start = currentTime - visibleDuration / 2
        let end = currentTime + visibleDuration / 2
        let originalLevels = original?.levels(from: start, to: end, count: count) ?? Array(repeating: 0, count: count)
        let processedLevels = processed?.levels(from: start, to: end, count: count)
        let maxHeight = size.height * 0.62
        let step = size.width / CGFloat(count)

        func bar(_ index: Int, level: Float, color: Color) {
            let height = max(3, maxHeight * CGFloat(min(1, level / peakLevel)))
            let rect = CGRect(
                x: CGFloat(index) * step + (step - Self.barWidth) / 2, y: (size.height - height) / 2,
                width: Self.barWidth, height: height
            )
            context.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(color))
        }

        for index in 0..<count {
            // Before the start or after the end of the audio there is nothing to draw.
            let barTime = start + (Double(index) + 0.5) * visibleDuration / Double(count)
            guard barTime >= 0, barTime <= duration else { continue }
            if let processedLevels {
                bar(index, level: originalLevels[index], color: .token(.waveformOriginal))
                bar(index, level: processedLevels[index], color: tint.wave)
            } else {
                bar(index, level: originalLevels[index], color: .token(.waveformIdle))
            }
        }
    }

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = zoomStart ?? visibleDuration
                zoomStart = base
                let longest = max(duration, Self.minimumVisibleDuration)
                visibleDuration = min(max(base / value.magnification, Self.minimumVisibleDuration), longest)
            }
            .onEnded { _ in zoomStart = nil }
    }

    /// Dragging moves the audio under the fixed playhead.
    private func scrub(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let base = scrubStart ?? currentTime
                scrubStart = base
                onScrub(base - Double(value.translation.width / max(width, 1)) * visibleDuration)
            }
            .onEnded { _ in scrubStart = nil }
    }
}
