import EchoCore
import SwiftUI

extension LoudnessTarget {
    var displayName: LocalizedStringKey {
        switch self {
        case .youtube: "YouTube"
        case .instagram: "Instagram"
        case .tiktok: "TikTok"
        case .spotify: "Spotify"
        case .podcast: "Podcast"
        case .appleMusic: "Apple Music"
        case .custom: "Custom"
        case .unknown: "From a newer version"
        }
    }
}

/// Auto Level's target (SPEC § 6.7): Off, a platform, or Custom. The gain it applies is shown below.
struct LoudnessSheet: View {
    let model: EditorModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTint) private var tint
    @State private var customLUFS = Float(LoudnessTarget.customDefault)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Auto Level brings the final mix to the loudness the platform expects.")
                        .font(.footnote)
                        .foregroundStyle(.token(.textSecondary))
                        .padding(.horizontal, 14)
                    GroupedRows {
                        row(nil, title: "Off", value: nil)
                        ForEach(LoudnessTarget.platformTargets, id: \.self) { target in
                            RowSeparator()
                            row(target, title: target.displayName, value: DisplayFormat.lufs(target.lufs))
                        }
                        RowSeparator()
                        // While Custom is chosen its slider shows the value.
                        let isCustom = model.outputLoudness?.isCustom == true
                        row(
                            .custom(lufs: Double(customLUFS)), title: "Custom",
                            value: isCustom ? nil : DisplayFormat.lufs(Double(customLUFS))
                        )
                        if isCustom {
                            RowSeparator()
                            ValueSlider(
                                title: "Target", value: $customLUFS, range: Self.customRange,
                                step: Float(LoudnessTarget.customStep),
                                format: { DisplayFormat.lufs(Double($0)) },
                                onEditingEnded: { model.setOutputLoudness(.custom(lufs: Double(customLUFS))) }
                            )
                        }
                    }
                    gainCaption
                        .font(.footnote)
                        .foregroundStyle(.token(.textSecondary))
                        .padding(.horizontal, 14)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Color.token(.ground).ignoresSafeArea())
            .navigationTitle("Loudness")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Full height like the other Adjust sheets, so Custom and the applied gain are in view.
        .presentationDetents([.large])
        .onAppear {
            if let target = model.outputLoudness, target.isCustom { customLUFS = Float(target.lufs) }
        }
    }

    private static let customRange = Float(LoudnessTarget.customRange.lowerBound)...Float(LoudnessTarget.customRange.upperBound)

    private func isSelected(_ target: LoudnessTarget?) -> Bool {
        switch (target, model.outputLoudness) {
        case (nil, nil): true
        case (.custom, .custom?): true
        case let (lhs?, rhs?): lhs == rhs
        default: false
        }
    }

    private func row(_ target: LoudnessTarget?, title: LocalizedStringKey, value: String?) -> some View {
        let isSelected = isSelected(target)
        return Button {
            model.setOutputLoudness(target)
        } label: {
            let titleText = Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.token(.textPrimary))
            let valueText = value.map {
                Text($0)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.token(.textValue))
            }
            let checkmark = Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(tint.text)
                .opacity(isSelected ? 1 : 0)
                .accessibilityHidden(true)
            // At large text sizes the value moves under the name.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    titleText.fixedSize()
                    Spacer(minLength: 8)
                    valueText?.fixedSize()
                    checkmark
                }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        titleText
                        valueText
                    }
                    Spacer(minLength: 8)
                    checkmark
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var gainCaption: some View {
        if model.outputLoudness != nil {
            if let gain = model.autoLevelGainDB {
                if abs(gain) >= AutoLevelAnalyzer.gainRange.upperBound {
                    Text("Auto Level applies \(DisplayFormat.decibels(Float(gain))), the most it can.")
                } else {
                    Text("Auto Level applies \(DisplayFormat.decibels(Float(gain))).")
                }
            } else {
                Text("Measuring…")
            }
        }
    }
}

#if DEBUG
#Preview("Loudness, dark") {
    LoudnessSheet(model: previewAdjustModel(outputLoudness: .youtube)).preferredColorScheme(.dark)
}

#Preview("Loudness, Custom, light") {
    LoudnessSheet(model: previewAdjustModel(outputLoudness: .custom(lufs: -23.5))).preferredColorScheme(.light)
}

#Preview("Loudness, Arabic XXL") {
    LoudnessSheet(model: previewAdjustModel(outputLoudness: .podcast)).previewArabicXXL()
}
#endif
