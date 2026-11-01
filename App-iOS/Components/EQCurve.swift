import EchoCore
import SwiftUI

/// The equalizer's response drawn left to right on a log frequency axis, ±18 dB tall (SPEC § 8).
struct EQCurveShape: Shape {
    /// Gain in dB at `EQCurveShape.frequencies`.
    let response: [Double]
    var insets = EdgeInsets()

    static let frequencies = EQResponse.logFrequencies(count: 96)
    static let gainLimit = Double(EQBand.gainRange.upperBound)

    init(bands: [EQBand], insets: EdgeInsets = EdgeInsets()) {
        response = EQResponse.magnitudeDB(of: bands, at: Self.frequencies)
        self.insets = insets
    }

    func path(in rect: CGRect) -> Path {
        let plot = rect.inset(by: insets)
        var path = Path()
        for (index, gain) in response.enumerated() {
            let point = CGPoint(
                x: plot.minX + plot.width * CGFloat(index) / CGFloat(max(response.count - 1, 1)),
                y: Self.y(gain: gain, in: plot)
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    static func x(frequency: Double, in plot: CGRect) -> CGFloat {
        let range = EQResponse.frequencyRange
        let position = log(frequency / range.lowerBound) / log(range.upperBound / range.lowerBound)
        return plot.minX + plot.width * CGFloat(min(max(position, 0), 1))
    }

    static func frequency(x: CGFloat, in plot: CGRect) -> Double {
        let range = EQResponse.frequencyRange
        let position = Double(min(max((x - plot.minX) / max(plot.width, 1), 0), 1))
        return range.lowerBound * pow(range.upperBound / range.lowerBound, position)
    }

    static func y(gain: Double, in plot: CGRect) -> CGFloat {
        let position = (min(max(gain, -gainLimit), gainLimit) + gainLimit) / (2 * gainLimit)
        return plot.maxY - plot.height * CGFloat(position)
    }

    static func gain(y: CGFloat, in plot: CGRect) -> Double {
        let position = Double(min(max((plot.maxY - y) / max(plot.height, 1), 0), 1))
        return position * 2 * gainLimit - gainLimit
    }
}

private extension CGRect {
    func inset(by insets: EdgeInsets) -> CGRect {
        CGRect(
            x: minX + insets.leading, y: minY + insets.top,
            width: max(0, width - insets.leading - insets.trailing), height: max(0, height - insets.top - insets.bottom)
        )
    }
}

/// The interactive equalizer graph: grid, response curve and a handle per band. Drag a handle to set its
/// frequency and gain; that also selects the band. Always left to right (SPEC § 8, § 17).
struct EQCurveView: View {
    let bands: [EQBand]
    let selectedBand: Int
    let onSelect: (Int) -> Void
    let onMove: (_ band: Int, _ frequency: Float, _ gain: Float) -> Void
    let onMoveEnded: () -> Void

    @Environment(\.appTint) private var tint
    /// Resets when a drag ends or is cancelled, so every drag is finished.
    @GestureState private var isDragging = false

    private static let inset: CGFloat = 16
    private static let handleSize: CGFloat = 18
    private static let space = "eqCurve"
    private static let gridFrequencies: [Double] = [100, 1_000, 10_000]

    var body: some View {
        GeometryReader { geometry in
            let plot = CGRect(origin: .zero, size: geometry.size).insetBy(dx: Self.inset, dy: Self.inset)
            ZStack(alignment: .topLeading) {
                grid(in: plot)
                EQCurveShape(bands: bands, insets: EdgeInsets(top: Self.inset, leading: Self.inset, bottom: Self.inset, trailing: Self.inset))
                    .stroke(EQResponse.isFlat(bands) ? Color.token(.waveformIdle) : tint.fill, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    .accessibilityHidden(true)
                ForEach(bands.indices, id: \.self) { index in
                    handle(index, in: plot)
                }
            }
            .coordinateSpace(.named(Self.space))
        }
        .frame(height: 200)
        .background(.token(.surface), in: .rect(cornerRadius: 12))
        .environment(\.layoutDirection, .leftToRight)
        // The graph has a fixed height; larger axis labels would cover the curve (SPEC § 17: no clipping).
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .onChange(of: isDragging) { _, isDragging in
            if !isDragging { onMoveEnded() }
        }
    }

    private func grid(in plot: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                let zero = EQCurveShape.y(gain: 0, in: plot)
                path.move(to: CGPoint(x: plot.minX, y: zero))
                path.addLine(to: CGPoint(x: plot.maxX, y: zero))
                for frequency in Self.gridFrequencies {
                    let x = EQCurveShape.x(frequency: frequency, in: plot)
                    path.move(to: CGPoint(x: x, y: plot.minY))
                    path.addLine(to: CGPoint(x: x, y: plot.maxY))
                }
            }
            .stroke(Color.token(.separator), lineWidth: 1)
            ForEach(Self.gridFrequencies, id: \.self) { frequency in
                Text(DisplayFormat.frequency(Float(frequency)))
                    .font(.caption2)
                    .foregroundStyle(.token(.textTertiary))
                    .fixedSize()
                    .offset(x: EQCurveShape.x(frequency: frequency, in: plot) + 4, y: plot.maxY - 14)
            }
        }
        .accessibilityHidden(true)
    }

    private func handle(_ index: Int, in plot: CGRect) -> some View {
        let band = bands[index]
        let center = CGPoint(
            x: EQCurveShape.x(frequency: Double(band.frequencyHz), in: plot),
            y: EQCurveShape.y(gain: Double(band.gainDB), in: plot)
        )
        let isSelected = index == selectedBand
        return Circle()
            .fill(isSelected ? tint.fill : Color.token(.surface))
            .overlay(Circle().strokeBorder(tint.fill, lineWidth: 2))
            .frame(width: Self.handleSize, height: Self.handleSize)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .position(center)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .updating($isDragging) { _, isDragging, _ in isDragging = true }
                    .onChanged { drag in
                        if !isSelected { onSelect(index) }
                        onMove(
                            index,
                            Float(EQCurveShape.frequency(x: drag.location.x, in: plot)),
                            Float(EQCurveShape.gain(y: drag.location.y, in: plot))
                        )
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(Text("Band \(index + 1), \(DisplayFormat.frequency(band.frequencyHz))"))
            .accessibilityValue(Text(DisplayFormat.decibels(band.gainDB)))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAdjustableAction { direction in
                onSelect(index)
                onMove(index, band.frequencyHz, band.gainDB + (direction == .increment ? 0.5 : -0.5))
                onMoveEnded()
            }
    }
}
