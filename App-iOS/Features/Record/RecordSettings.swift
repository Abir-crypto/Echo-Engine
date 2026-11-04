import EchoCore
import SwiftUI

/// The Record screen's sheets.
enum RecordSheet: String, Identifiable {
    case input, noiseReduction, inputGain, monitor
    var id: Self { self }
}

extension SuppressionLevel {
    var displayName: Text {
        switch self {
        case .off: Text("Off")
        // Own keys: the export's "Standard" and the EQ's "High" may translate differently.
        case .standard:
            Text(String(localized: "recording.noiseReduction.standard", defaultValue: "Standard",
                        comment: "Noise reduction level: Apple voice processing and a noise gate."))
        case .high:
            Text(String(localized: "recording.noiseReduction.high", defaultValue: "High",
                        comment: "Noise reduction level: on-device noise removal."))
        }
    }
}

/// Noise reduction, Input gain and, with headphones, Monitor (mockup's grouped rows; SPEC § 13.1, § 13.4). Adjustable
/// during a take too.
struct RecordSettingsRows: View {
    let model: RecordModel
    let open: (RecordSheet) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupedRows {
                SettingRow(title: Text("Noise reduction"), value: model.suppression.level.displayName,
                           isOff: model.suppression.level == .off) { open(.noiseReduction) }
                RowSeparator()
                SettingRow(title: Text("Input gain"), value: Text(DisplayFormat.decibels(Float(model.inputGainDB))),
                           isOff: model.inputGainDB == 0) { open(.inputGain) }
                if model.offersMonitoring {
                    RowSeparator()
                    SettingRow(
                        title: Text("Monitor"),
                        value: model.isMonitoring ? Text(DisplayFormat.percent(Float(model.monitorVolume))) : Text("Off"),
                        isOff: !model.isMonitoring
                    ) { open(.monitor) }
                }
            }
            if let caption = SuppressionCaption(state: model.suppression) {
                caption.text
                    .font(.footnote)
                    .foregroundStyle(.token(.textSecondary))
                    .padding(.horizontal, 14)
            }
            if model.showsWiredHeadphonesTip {
                Label {
                    Text("Use wired headphones for monitoring")
                } icon: {
                    Image(systemName: "cable.connector")
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.token(.textValue))
                .padding(.horizontal, 14)
            }
        }
    }
}

/// A grouped row: title, value (`TextTertiary` when off, as in the mockup) and a chevron.
private struct SettingRow: View {
    let title: Text
    let value: Text
    let isOff: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                title
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.token(.textPrimary))
                Spacer(minLength: 8)
                value
                    .font(.subheadline)
                    .foregroundStyle(isOff ? .token(.textTertiary) : .token(.textValue))
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.token(.iconMuted))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// What the Noise reduction row says when the input changes what runs (SPEC § 13.4).
struct SuppressionCaption {
    let text: Text

    init?(state: SuppressionState) {
        if state.level == .high, state.effective == .standard {
            text = Text("High needs a wired or built-in microphone, so Standard is used.")
        } else if state.isGateOnly {
            text = Text("With this input, Standard uses a noise gate only.")
        } else {
            return nil
        }
    }
}

/// Off, Standard or High, each explained (SPEC § 13.4).
struct NoiseReductionSheet: View {
    let model: RecordModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTint) private var tint

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    GroupedRows {
                        option(.off, description: Text("Records the microphone as it is."))
                        RowSeparator()
                        option(.standard, description: Text("Apple’s voice processing with a noise gate. Good for speech in a quiet room."))
                        RowSeparator()
                        option(.high, description: Text("Removes steady noise like fans and traffic, on your iPhone. While monitoring you hear yourself about 30 ms later."))
                    }
                    if let caption = SuppressionCaption(state: model.suppression) {
                        caption.text
                            .font(.footnote)
                            .foregroundStyle(.token(.textSecondary))
                            .padding(.horizontal, 14)
                    }
                    if model.hasTake {
                        Text("Changing to or from Standard during a recording leaves a short gap.")
                            .font(.footnote)
                            .foregroundStyle(.token(.textSecondary))
                            .padding(.horizontal, 14)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Color.token(.ground).ignoresSafeArea())
            .navigationTitle(Text("Noise reduction"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func option(_ level: SuppressionLevel, description: Text) -> some View {
        let isSelected = model.suppression.level == level
        return Button {
            model.setSuppression(level)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    level.displayName
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.token(.textPrimary))
                    description
                        .font(.footnote)
                        .foregroundStyle(.token(.textSecondary))
                }
                Spacer(minLength: 8)
                if isSelected {
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The input gain, set while watching the meters (SPEC § 13.4).
struct InputGainSheet: View {
    let model: RecordModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupedRows {
                        ValueSlider(
                            title: "Input gain",
                            value: Binding(get: { Float(model.inputGainDB) }, set: { model.setInputGain(Double($0)) }),
                            range: -24...24, step: 0.5,
                            format: { DisplayFormat.decibels($0) },
                            onEditingEnded: { model.commitInputGain() }
                        )
                    }
                    Text("Set it so your loudest parts stay out of the red. It changes the processed recording; the original keeps the microphone’s level.")
                        .font(.footnote)
                        .foregroundStyle(.token(.textSecondary))
                        .padding(.horizontal, 14)
                    ChannelMeters(model: model)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Color.token(.ground).ignoresSafeArea())
            .navigationTitle(Text("Input gain"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Hearing yourself through headphones (user decision, SPEC § 13.4).
struct MonitorSheet: View {
    let model: RecordModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    GroupedRows {
                        ToggleRow(
                            title: "Hear yourself", caption: "Plays what’s recorded into your headphones.",
                            isOn: Binding(get: { model.isMonitoring }, set: { model.setMonitoring($0) })
                        )
                        if model.isMonitoring {
                            RowSeparator()
                            ValueSlider(
                                title: "Volume",
                                value: Binding(get: { Float(model.monitorVolume) }, set: { model.setMonitorVolume(Double($0)) }),
                                range: 0...1, step: 0.05,
                                format: { DisplayFormat.percent($0) },
                                onEditingEnded: {}
                            )
                        }
                    }
                    Text("Only through headphones, never the speaker.")
                        .font(.footnote)
                        .foregroundStyle(.token(.textSecondary))
                        .padding(.horizontal, 14)
                    if model.suppression.effective == .high {
                        Text("With High noise reduction you hear yourself about 30 ms later.")
                            .font(.footnote)
                            .foregroundStyle(.token(.textSecondary))
                            .padding(.horizontal, 14)
                    }
                    if model.outputKind == .bluetooth {
                        Text("Bluetooth headphones add a delay. Wired headphones are best for monitoring.")
                            .font(.footnote)
                            .foregroundStyle(.token(.textSecondary))
                            .padding(.horizontal, 14)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Color.token(.ground).ignoresSafeArea())
            .navigationTitle(Text("Monitor"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
