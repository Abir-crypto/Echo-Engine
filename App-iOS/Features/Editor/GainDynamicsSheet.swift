import EchoCore
import SwiftUI

/// Input gain, noise gate, compressor, de-esser and limiter (SPEC § 8): essentials visible, timings under "Advanced".
struct GainDynamicsSheet: View {
    let model: EditorModel

    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<Section> = []

    private enum Section {
        case gate, compressor, deEsser
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupedRows {
                        slider("Input gain", \.inputGainDB, ManualSettings.inputGainRange, step: 0.5, format: decibels)
                    }
                    gate
                    compressor
                    deEsser
                    limiter
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Color.token(.ground).ignoresSafeArea())
            .navigationTitle("Gain and dynamics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var manual: ManualSettings { model.manual }

    private var gate: some View {
        GroupedRows {
            ToggleRow(title: "Noise gate", caption: "Quiets the audio between words.", isOn: model.toggleBinding(\.gate.isEnabled))
            if manual.gate.isEnabled {
                RowSeparator()
                slider("Threshold", \.gate.thresholdDB, ManualSettings.Gate.thresholdRange, step: 1, format: decibels)
                RowSeparator()
                advanced(.gate) {
                    slider("Range", \.gate.rangeDB, ManualSettings.Gate.attenuationRange, step: 1, format: decibels)
                    RowSeparator()
                    slider("Attack", \.gate.attackMs, ManualSettings.Gate.attackRange, scale: .logarithmic, format: milliseconds)
                    RowSeparator()
                    slider("Release", \.gate.releaseMs, ManualSettings.Gate.releaseRange, scale: .logarithmic, format: milliseconds)
                }
            }
        }
    }

    private var compressor: some View {
        GroupedRows {
            ToggleRow(title: "Compressor", caption: "Evens out loud and quiet parts.", isOn: model.toggleBinding(\.compressor.isEnabled))
            if manual.compressor.isEnabled {
                RowSeparator()
                slider("Threshold", \.compressor.thresholdDB, ManualSettings.Compressor.thresholdRange, step: 1, format: decibels)
                RowSeparator()
                slider("Ratio", \.compressor.ratio, ManualSettings.Compressor.ratioRange, step: 0.1, scale: .logarithmic, format: ratio)
                RowSeparator()
                slider("Makeup gain", \.compressor.makeupDB, ManualSettings.Compressor.makeupRange, step: 0.5, format: decibels)
                RowSeparator()
                advanced(.compressor) {
                    slider("Attack", \.compressor.attackMs, ManualSettings.Compressor.attackRange, scale: .logarithmic, format: milliseconds)
                    RowSeparator()
                    slider("Release", \.compressor.releaseMs, ManualSettings.Compressor.releaseRange, scale: .logarithmic, format: milliseconds)
                }
            }
        }
    }

    private var deEsser: some View {
        GroupedRows {
            ToggleRow(title: "De-esser", caption: "Softens harsh “s” sounds.", isOn: model.toggleBinding(\.deEsser.isEnabled))
            if manual.deEsser.isEnabled {
                RowSeparator()
                slider("Amount", \.deEsser.amount, ManualSettings.unitRange, step: 0.01, format: percent)
                RowSeparator()
                advanced(.deEsser) {
                    slider("Frequency", \.deEsser.frequencyHz, ManualSettings.DeEsser.frequencyRange, step: 100, format: frequency)
                }
            }
        }
    }

    private var limiter: some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupedRows {
                slider("Limiter ceiling", \.limiter.ceilingDB, ManualSettings.Limiter.ceilingRange, step: 0.1, format: decibels)
            }
            Text("Always on: peaks never go above the ceiling.")
                .font(.footnote)
                .foregroundStyle(.token(.textSecondary))
                .padding(.horizontal, 14)
        }
    }

    private func advanced(_ section: Section, @ViewBuilder content: () -> some View) -> some View {
        let rows = content()
        return DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(section) },
            set: { isExpanded in
                if isExpanded { expanded.insert(section) } else { expanded.remove(section) }
            }
        )) {
            VStack(spacing: 0) { rows }
        } label: {
            Text("Advanced")
        }
        .disclosureGroupStyle(AdvancedDisclosureStyle())
    }

    private func slider(
        _ title: LocalizedStringKey,
        _ keyPath: WritableKeyPath<ManualSettings, Float>,
        _ range: ClosedRange<Float>,
        step: Float? = nil,
        scale: ValueSlider.Scale = .linear,
        format: @escaping (Float) -> String
    ) -> ValueSlider {
        ValueSlider(
            title: title, value: model.binding(keyPath), range: range, step: step, scale: scale, format: format,
            onEditingEnded: model.finishAdjusting
        )
    }

    private func decibels(_ value: Float) -> String { DisplayFormat.decibels(value) }
    private func milliseconds(_ value: Float) -> String { DisplayFormat.milliseconds(value) }
    private func ratio(_ value: Float) -> String { DisplayFormat.ratio(value) }
    private func percent(_ value: Float) -> String { DisplayFormat.percent(value) }
    private func frequency(_ value: Float) -> String { DisplayFormat.frequency(value) }
}

#if DEBUG
#Preview("Gain and dynamics, dark") {
    GainDynamicsSheet(model: previewAdjustModel()).preferredColorScheme(.dark)
}

#Preview("Gain and dynamics, light") {
    GainDynamicsSheet(model: previewAdjustModel()).preferredColorScheme(.light)
}

#Preview("Gain and dynamics, Arabic XXL") {
    GainDynamicsSheet(model: previewAdjustModel()).previewArabicXXL()
}
#endif
