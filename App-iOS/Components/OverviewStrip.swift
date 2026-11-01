import EchoCore
import SwiftUI

/// The full-length waveform with trim handles, dimmed regions outside the trim and the playhead. Tap or drag to
/// seek; drag a handle to trim. Always left to right (SPEC § 9, § 17).
struct OverviewStrip: View {
    let peaks: WaveformPeaks?
    let peakLevel: Float
    let duration: Double
    let trim: TimeRangeCodable
    let currentTime: Double
    let isProcessed: Bool
    let isEditable: Bool
    var height: CGFloat = 60
    let onSeek: (Double) -> Void
    let onTrimStart: (Double) -> Void
    let onTrimEnd: (Double) -> Void
    let onTrimEnded: () -> Void

    @Environment(\.appTint) private var tint

    private static let barCount = 56
    private static let handleWidth: CGFloat = 8
    /// Touch target around each handle (SPEC § 17).
    private static let handleHitWidth: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawBars(in: &context, size: size)
                }
                dim(from: 0, to: x(trim.start, width))
                dim(from: x(trim.end, width), to: width)
                Rectangle()
                    .fill(.token(.playhead))
                    .frame(width: 2, height: height + 4)
                    .offset(x: x(currentTime, width) - 1, y: -2)
                    .accessibilityElement()
                    .accessibilityLabel(Text("Playhead"))
                    .accessibilityValue(Text(DisplayFormat.duration(currentTime)))
                    .accessibilityAdjustableAction { direction in
                        onSeek(currentTime + (direction == .increment ? 5 : -5))
                    }
                handle(at: trim.start, width: width, label: Text("Trim start"), onMove: onTrimStart)
                handle(at: trim.end, width: width, label: Text("Trim end"), onMove: onTrimEnd)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onSeek(time(at: $0.location.x, width)) }
            )
            .coordinateSpace(.named(Self.space))
        }
        .frame(height: height)
        .background(.token(.surface), in: .rect(cornerRadius: 12))
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .contain)
    }

    private static let space = "overviewStrip"

    private func x(_ time: Double, _ width: CGFloat) -> CGFloat {
        duration > 0 ? width * CGFloat(min(max(time / duration, 0), 1)) : 0
    }

    private func time(at x: CGFloat, _ width: CGFloat) -> Double {
        duration * Double(min(max(x / max(width, 1), 0), 1))
    }

    private func drawBars(in context: inout GraphicsContext, size: CGSize) {
        let levels = peaks?.levels(from: 0, to: duration, count: Self.barCount) ?? Array(repeating: 0, count: Self.barCount)
        let inset: CGFloat = 6, gap: CGFloat = 2
        let barWidth = max(1, (size.width - inset * 2 - gap * CGFloat(Self.barCount - 1)) / CGFloat(Self.barCount))
        for (index, level) in levels.enumerated() {
            let barX = inset + CGFloat(index) * (barWidth + gap)
            let barTime = duration * Double(barX + barWidth / 2) / Double(max(size.width, 1))
            let isInside = trim.contains(barTime)
            let height = max(3, size.height * 0.7 * CGFloat(min(1, level / peakLevel)))
            let rect = CGRect(x: barX, y: (size.height - height) / 2, width: barWidth, height: height)
            let color: Color = isInside && isProcessed ? tint.wave : .token(.waveformIdle)
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
        }
    }

    private func dim(from start: CGFloat, to end: CGFloat) -> some View {
        Rectangle()
            .fill(.token(.dim))
            .frame(width: max(0, end - start), height: height)
            .offset(x: start)
            .allowsHitTesting(false)
    }

    /// An 8 pt handle centred on the trim edge (kept inside the strip) with a 44 pt touch target.
    private func handle(at time: Double, width: CGFloat, label: Text, onMove: @escaping (Double) -> Void) -> some View {
        let center = min(max(x(time, width), Self.handleWidth / 2), width - Self.handleWidth / 2)
        return RoundedRectangle(cornerRadius: 4)
            .fill(tint.fill)
            .frame(width: Self.handleWidth, height: height)
            .frame(width: Self.handleHitWidth, height: height)
            .contentShape(Rectangle())
            .offset(x: center - Self.handleHitWidth / 2)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { onMove(self.time(at: $0.location.x, width)) }
                    .onEnded { _ in onTrimEnded() }
            )
            .opacity(isEditable ? 1 : 0.4)
            .allowsHitTesting(isEditable)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(Text(DisplayFormat.duration(time)))
            .accessibilityAdjustableAction { direction in
                onMove(time + (direction == .increment ? 1 : -1))
                onTrimEnded()
            }
    }
}
