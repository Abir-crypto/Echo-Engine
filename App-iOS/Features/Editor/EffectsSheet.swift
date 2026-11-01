import EchoCore
import SwiftUI

/// Pitch shift and reverb (SPEC § 8).
struct EffectsSheet: View {
    let model: EditorModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        GroupedRows {
                            ValueSlider(
                                title: "Pitch", value: model.binding(\.pitchSemitones), range: ManualSettings.pitchRange, step: 1,
                                format: { DisplayFormat.semitones($0) }, spokenValue: DisplayFormat.semitonesDescription,
                                onEditingEnded: model.finishAdjusting
                            )
                        }
                        Text("In semitones. The voice keeps its natural character.")
                            .font(.footnote)
                            .foregroundStyle(.token(.textSecondary))
                            .padding(.horizontal, 14)
                    }
                    GroupedRows {
                        ToggleRow(title: "Reverb", caption: "Adds the sound of a room.", isOn: model.toggleBinding(\.reverb.isEnabled))
                        if model.manual.reverb.isEnabled {
                            RowSeparator()
                            slider("Room size", \.reverb.roomSize)
                            RowSeparator()
                            slider("Damping", \.reverb.damping)
                            RowSeparator()
                            slider("Mix", \.reverb.mix)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Color.token(.ground).ignoresSafeArea())
            .navigationTitle("Effects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func slider(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<ManualSettings, Float>) -> ValueSlider {
        ValueSlider(
            title: title, value: model.binding(keyPath), range: ManualSettings.unitRange, step: 0.01,
            format: { DisplayFormat.percent($0) }, onEditingEnded: model.finishAdjusting
        )
    }
}

#if DEBUG
#Preview("Effects, dark") {
    EffectsSheet(model: previewAdjustModel()).preferredColorScheme(.dark)
}

#Preview("Effects, light") {
    EffectsSheet(model: previewAdjustModel()).preferredColorScheme(.light)
}

#Preview("Effects, Arabic XXL") {
    EffectsSheet(model: previewAdjustModel()).previewArabicXXL()
}
#endif
