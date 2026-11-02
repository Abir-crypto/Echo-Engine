import EchoCore
import SwiftUI

/// "Apply preset…" from the Enhance menu (SPEC § 9, § 12): built-ins, then the person's presets. Tapping one
/// replaces the AI stack, manual chain and loudness as one undo step.
struct ApplyPresetSheet: View {
    let model: EditorModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTint) private var tint

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Replaces the enhancements, adjustments and loudness. The trim stays, and Undo brings back what you had.")
                        .font(.footnote)
                        .foregroundStyle(.token(.textSecondary))
                    section("Built-in", presets: model.presets.filter(\.isBuiltIn))
                    let mine = model.presets.filter { !$0.isBuiltIn }
                    if !mine.isEmpty {
                        section("Your presets", presets: mine)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Color.token(.ground).ignoresSafeArea())
            .navigationTitle("Apply preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await model.reloadPresets() }
    }

    private func section(_ title: LocalizedStringKey, presets: [Preset]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.token(.textSecondary))
                .accessibilityAddTraits(.isHeader)
            GroupedRows {
                ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                    if index > 0 { RowSeparator() }
                    row(preset)
                }
            }
        }
    }

    private func row(_ preset: Preset) -> some View {
        let isBase = model.project.basePresetID == preset.id
        return Button {
            model.applyPreset(preset)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.token(.textPrimary))
                    Text(steps(of: preset))
                        .font(.footnote)
                        .foregroundStyle(.token(.textSecondary))
                }
                Spacer(minLength: 8)
                if let target = preset.outputLoudness {
                    Text(target.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.token(.textValue))
                }
                if isBase {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(tint.text)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 60)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isBase ? .isSelected : [])
    }

    /// "Noise Suppression and Voice Leveler", in the locale's list style.
    private func steps(of preset: Preset) -> String {
        guard !preset.aiStack.isEmpty else {
            return String(localized: "No enhancements", comment: "A preset without AI steps.")
        }
        return preset.aiStack.map(\.kind.localizedName).formatted(.list(type: .and))
    }
}
