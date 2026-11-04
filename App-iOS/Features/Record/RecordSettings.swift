import EchoCore
import SwiftUI

/// The Record screen's sheets.
enum RecordSheet: String, Identifiable {
    case input, noiseReduction, autoTune, inputGain, monitor
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
                SettingRow(
                    title: Text("Auto-tune"),
                    value: model.autoTune.isOn ? Text(model.autoTune.summary) : Text("Off"),
                    isOff: !model.autoTune.isOn
                ) { open(.autoTune) }
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

/// Note names, localized (Do, Ré, Mi… where that's the custom).
enum NoteName {
    static func name(_ key: Int) -> String {
        switch ((key % 12) + 12) % 12 {
        case 0: String(localized: "note.c", defaultValue: "C", comment: "Note name C (Do).")
        case 1: String(localized: "note.cSharp", defaultValue: "C♯", comment: "Note name C sharp (Do dièse).")
        case 2: String(localized: "note.d", defaultValue: "D", comment: "Note name D (Ré).")
        case 3: String(localized: "note.dSharp", defaultValue: "D♯", comment: "Note name D sharp (Ré dièse).")
        case 4: String(localized: "note.e", defaultValue: "E", comment: "Note name E (Mi).")
        case 5: String(localized: "note.f", defaultValue: "F", comment: "Note name F (Fa).")
        case 6: String(localized: "note.fSharp", defaultValue: "F♯", comment: "Note name F sharp (Fa dièse).")
        case 7: String(localized: "note.g", defaultValue: "G", comment: "Note name G (Sol).")
        case 8: String(localized: "note.gSharp", defaultValue: "G♯", comment: "Note name G sharp (Sol dièse).")
        case 9: String(localized: "note.a", defaultValue: "A", comment: "Note name A (La).")
        case 10: String(localized: "note.aSharp", defaultValue: "A♯", comment: "Note name A sharp (La dièse).")
        default: String(localized: "note.b", defaultValue: "B", comment: "Note name B (Si).")
        }
    }
}

extension AutoTuneSettings {
    /// "A minor", "C major" or "Chromatic".
    var keyDescription: String {
        guard let key else { return String(localized: "Chromatic", comment: "Auto-tune key: every note is allowed.") }
        let note = NoteName.name(key)
        return scale == .minor
            ? String(localized: "\(note) minor", comment: "A key in minor, e.g. A minor.")
            : String(localized: "\(note) major", comment: "A key in major, e.g. C major.")
    }

    /// The Auto-tune row's value (SPEC § 13.1): "A minor, natural".
    var summary: String {
        let key = keyDescription
        return isRobotic
            ? String(localized: "\(key), robotic", comment: "Auto-tune row value: key and style, e.g. A minor, robotic.")
            : String(localized: "\(key), natural", comment: "Auto-tune row value: key and style, e.g. A minor, natural.")
    }
}

/// Auto-tune (SPEC § 13.5): on/off, key (Chromatic by default), scale, Natural ↔ Robotic, and Advanced: humanize and
/// formant preservation. Changes apply at once; released controls are logged in the take.
struct AutoTuneSheet: View {
    let model: RecordModel

    @Environment(\.dismiss) private var dismiss

    private var settings: AutoTuneSettings { model.autoTune }

    /// A setting that applies and is committed at once (switches, pickers).
    private func binding<Value>(_ keyPath: WritableKeyPath<AutoTuneSettings, Value>) -> Binding<Value> {
        Binding(get: { model.autoTune[keyPath: keyPath] }, set: { value in
            var settings = model.autoTune
            settings[keyPath: keyPath] = value
            model.setAutoTune(settings)
            model.commitAutoTune()
        })
    }

    /// A slider: applies while it moves, committed on release.
    private func sliding(_ keyPath: WritableKeyPath<AutoTuneSettings, Double>) -> Binding<Float> {
        Binding(get: { Float(model.autoTune[keyPath: keyPath]) }, set: { value in
            var settings = model.autoTune
            settings[keyPath: keyPath] = Double(value)
            model.setAutoTune(settings)
        })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    GroupedRows {
                        ToggleRow(title: "Auto-tune", caption: "Pulls your voice to the nearest note as you sing.", isOn: binding(\.isOn))
                    }
                    if settings.isOn {
                        GroupedRows {
                            HStack {
                                Text("Key")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.token(.textPrimary))
                                Spacer()
                                Picker(selection: Binding(get: { settings.key ?? -1 }, set: { binding(\.key).wrappedValue = $0 < 0 ? nil : $0 })) {
                                    Text("Chromatic", comment: "Auto-tune key: every note is allowed.").tag(-1)
                                    ForEach(0..<12, id: \.self) { Text(NoteName.name($0)).tag($0) }
                                } label: {
                                    Text("Key")
                                }
                                .pickerStyle(.menu)
                                .tint(.token(.textValue))
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 52)
                            if settings.key != nil {
                                RowSeparator()
                                Picker(selection: binding(\.scale)) {
                                    Text("Major", comment: "Auto-tune scale.").tag(AutoTuneSettings.Scale.major)
                                    Text("Minor", comment: "Auto-tune scale.").tag(AutoTuneSettings.Scale.minor)
                                } label: {
                                    Text("Scale")
                                }
                                .pickerStyle(.segmented)
                                .padding(14)
                            }
                            RowSeparator()
                            ValueSlider(
                                title: "Style", value: sliding(\.style), range: 0...1, step: 0.05,
                                format: { $0 > 0.5
                                    ? String(localized: "Robotic", comment: "Auto-tune style: snaps to the note at once.")
                                    : String(localized: "Natural", comment: "Auto-tune style: glides to the note.") },
                                onEditingEnded: { model.commitAutoTune() }
                            )
                        }
                        Text("Natural lets your voice glide to the note; Robotic snaps to it at once.")
                            .font(.footnote)
                            .foregroundStyle(.token(.textSecondary))
                            .padding(.horizontal, 14)

                        DisclosureGroup {
                            GroupedRows {
                                ValueSlider(
                                    title: "Humanize", value: sliding(\.humanize), range: 0...1, step: 0.05,
                                    format: { DisplayFormat.percent($0) }, onEditingEnded: { model.commitAutoTune() }
                                )
                                RowSeparator()
                                ToggleRow(
                                    title: "Keep voice character",
                                    caption: "Off makes the voice brighter or darker as the pitch moves.",
                                    isOn: binding(\.preservesFormants)
                                )
                            }
                            .padding(.top, 8)
                        } label: {
                            Text("Advanced")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.token(.textValue))
                        }
                        .padding(.top, 10)

                        Text("While auto-tune is on you hear yourself about 26 ms later. Wired headphones keep the delay lowest.")
                            .font(.footnote)
                            .foregroundStyle(.token(.textSecondary))
                            .padding(.horizontal, 14)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Color.token(.ground).ignoresSafeArea())
            .navigationTitle(Text("Auto-tune"))
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
