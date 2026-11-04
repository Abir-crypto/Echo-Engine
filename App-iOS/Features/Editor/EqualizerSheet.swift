import EchoCore
import SwiftUI

/// Six bands on a draggable curve; the selected band's Frequency, Gain and Q below; Reset (SPEC § 8).
struct EqualizerSheet: View {
    let model: EditorModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTint) private var tint
    @State private var selectedBand = 2

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    EQCurveView(
                        bands: bands,
                        selectedBand: selectedBand,
                        onSelect: { selectedBand = $0 },
                        onMove: move,
                        onMoveEnded: model.finishAdjusting
                    )
                    bandPicker
                    if bands.indices.contains(selectedBand) {
                        bandControls(selectedBand)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Color.token(.ground).ignoresSafeArea())
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset", action: model.resetEqualizer)
                        .disabled(bands == EQBand.defaultBands)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var bands: [EQBand] { model.manual.eq }

    private func move(_ index: Int, frequency: Float, gain: Float) {
        model.adjust { manual in
            guard manual.eq.indices.contains(index) else { return }
            manual.eq[index].frequencyHz = min(max(frequency, EQBand.frequencyRange.lowerBound), EQBand.frequencyRange.upperBound)
            manual.eq[index].gainDB = (min(max(gain, EQBand.gainRange.lowerBound), EQBand.gainRange.upperBound) * 2).rounded() / 2
        }
    }

    /// Bands in frequency order, left to right like the graph; two rows when they don't fit.
    private var bandPicker: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ForEach(bands.indices, id: \.self) { chip($0) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(bands.indices, id: \.self) { chip($0) }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func chip(_ index: Int) -> some View {
        let isSelected = index == selectedBand
        return Button { selectedBand = index } label: {
            Text(chipTitle(bands[index]))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(isSelected ? tint.on : Color.token(.textPrimary))
                .background(isSelected ? tint.fill : Color.token(.surface), in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Band \(index + 1), \(DisplayFormat.frequency(bands[index].frequencyHz))"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func chipTitle(_ band: EQBand) -> String {
        switch band.kind {
        case .lowShelf: String(localized: "Low", comment: "EQ band chip: the low shelf band.")
        case .highShelf: String(localized: "High", comment: "EQ band chip: the high shelf band.")
        case .peaking, .unknown: DisplayFormat.compactFrequency(band.frequencyHz)
        }
    }

    private func kindName(_ kind: EQBand.Kind) -> Text {
        switch kind {
        case .lowShelf: Text("Low shelf")
        case .peaking: Text("Peak")
        case .highShelf: Text("High shelf")
        case .unknown: Text("Not available in this version")
        }
    }

    private func bandControls(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            kindName(bands[index].kind)
                .font(.footnote)
                .foregroundStyle(.token(.textSecondary))
                .padding(.leading, 14)
            GroupedRows {
                ValueSlider(
                    title: "Frequency", value: model.binding(\.eq[index].frequencyHz), range: EQBand.frequencyRange,
                    scale: .logarithmic, format: { DisplayFormat.frequency($0) }, isLeftToRight: true,
                    onEditingEnded: model.finishAdjusting
                )
                RowSeparator()
                ValueSlider(
                    title: "Gain", value: model.binding(\.eq[index].gainDB), range: EQBand.gainRange, step: 0.5,
                    format: { DisplayFormat.decibels($0) }, onEditingEnded: model.finishAdjusting
                )
                RowSeparator()
                ValueSlider(
                    title: "Q", value: model.binding(\.eq[index].q), range: EQBand.qRange, scale: .logarithmic,
                    format: { DisplayFormat.quality($0) }, onEditingEnded: model.finishAdjusting
                )
            }
            .disabled(bands[index].kind == .unknown)
        }
    }
}

#if DEBUG
#Preview("Equalizer, dark") {
    EqualizerSheet(model: previewAdjustModel()).preferredColorScheme(.dark)
}

#Preview("Equalizer, light") {
    EqualizerSheet(model: previewAdjustModel()).preferredColorScheme(.light)
}

#Preview("Equalizer, Arabic XXL") {
    EqualizerSheet(model: previewAdjustModel()).previewArabicXXL()
}
#endif
