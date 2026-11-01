import EchoCore
import SwiftUI

/// Lists the AI features with one line each (SPEC § 9). Features already in the stack show a checkmark.
struct AddEnhancementSheet: View {
    let model: EditorModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                GroupedRows {
                    ForEach(Array(EditorModel.offeredFeatures.enumerated()), id: \.element) { index, feature in
                        if index > 0 { RowSeparator() }
                        row(feature)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Color.token(.ground).ignoresSafeArea())
            .navigationTitle("Add enhancement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ feature: AIFeature) -> some View {
        let isAdded = model.aiStack.contains { $0.kind == feature }
        let isAvailable = model.isAvailable(feature)
        return Button {
            model.addEnhancement(feature)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.token(.textPrimary))
                    Text(isAvailable ? feature.summary : "Not available on this device")
                        .font(.footnote)
                        .foregroundStyle(.token(.textSecondary))
                }
                Spacer(minLength: 8)
                if isAdded {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.token(.textValue))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canAdd(feature))
        .accessibilityValue(isAdded ? Text("Added") : Text(verbatim: ""))
    }
}

/// One step's strength, the wet/dry mix (SPEC § 7). It applies when the slider is released: one undo step and one
/// render.
struct StrengthSheet: View {
    let model: EditorModel
    let index: Int

    @Environment(\.dismiss) private var dismiss
    @State private var strength: Float = 0

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                GroupedRows {
                    ValueSlider(
                        title: "Strength", value: $strength, range: 0...1, step: 0.01,
                        format: { DisplayFormat.percent($0) },
                        onEditingEnded: { model.setStrength(strength, at: index) }
                    )
                }
                Text("How much of the enhanced sound is mixed with the original.")
                    .font(.footnote)
                    .foregroundStyle(.token(.textSecondary))
                    .padding(.horizontal, 14)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.token(.ground).ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { strength = model.aiStack.indices.contains(index) ? model.aiStack[index].strength : 0 }
    }

    private var title: Text {
        model.aiStack.indices.contains(index) ? Text(model.aiStack[index].kind.displayName) : Text("Strength")
    }
}

#if DEBUG
#Preview("Add enhancement, dark") {
    AddEnhancementSheet(model: previewAdjustModel()).preferredColorScheme(.dark)
}

#Preview("Add enhancement, Arabic XXL") {
    AddEnhancementSheet(model: previewAdjustModel()).previewArabicXXL()
}

#Preview("Strength, light") {
    StrengthSheet(model: previewAdjustModel(), index: 0).preferredColorScheme(.light)
}
#endif
