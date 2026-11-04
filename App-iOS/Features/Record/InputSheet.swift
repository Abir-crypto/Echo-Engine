import EchoCore
import SwiftUI

/// Chooses the input and what it records (SPEC § 13.2; designed natively, user decision): every input iOS offers, the
/// built-in mic's Mono/Stereo, and for an interface its channels, each named and metered live. Locked while recording.
struct InputSheet: View {
    let model: RecordModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTint) private var tint

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    GroupedRows {
                        ForEach(Array(model.inputs.enumerated()), id: \.element.id) { position, input in
                            if position > 0 { RowSeparator() }
                            inputRow(input)
                        }
                    }

                    if model.offersStereo {
                        sectionTitle(Text("Built-in microphone"))
                            .padding(.top, 10)
                        GroupedRows {
                            Picker(
                                selection: Binding(get: { model.builtInMode }, set: { model.setBuiltInMode($0) })
                            ) {
                                Text("Mono", comment: "Built-in mic records one channel.").tag(BuiltInMicMode.mono)
                                Text("Stereo", comment: "Built-in mic records left and right.").tag(BuiltInMicMode.stereo)
                            } label: {
                                Text("Built-in microphone")
                            }
                            .pickerStyle(.segmented)
                            .padding(14)
                        }
                    }

                    if model.offersChannelChoice {
                        sectionTitle(Text("Channels", comment: "Section of the input sheet: the interface's channels."))
                            .padding(.top, 10)
                        GroupedRows {
                            ForEach(Array(model.channels.enumerated()), id: \.element.id) { position, channel in
                                if position > 0 { RowSeparator() }
                                ChannelRow(model: model, channel: channel)
                            }
                        }
                        Text("Choose the channels to record and name them. They’re mixed into one recording, and each is also kept on its own.")
                            .font(.footnote)
                            .foregroundStyle(.token(.textSecondary))
                            .padding(.horizontal, 14)
                    }

                    Text("iOS records from one input at a time. To record several microphones, connect an audio interface and choose its channels.")
                        .font(.footnote)
                        .foregroundStyle(.token(.textSecondary))
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Color.token(.ground).ignoresSafeArea())
            .navigationTitle(Text("Input", comment: "Input device button before one is known."))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func sectionTitle(_ title: Text) -> some View {
        title
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.token(.textSecondary))
            .padding(.horizontal, 14)
    }

    private func inputRow(_ input: AudioInput) -> some View {
        let isSelected = input.id == model.selectedInputID
        return Button {
            model.selectInput(id: input.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: Self.symbol(for: input.kind))
                    .font(.body)
                    .foregroundStyle(.token(.textValue))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(input.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.token(.textPrimary))
                    if input.hasHigherDelay {
                        Text("Higher delay, not ideal with auto-tune or backing tracks")
                            .font(.footnote)
                            .foregroundStyle(.token(.textSecondary))
                    }
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
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private static func symbol(for kind: AudioInput.Kind) -> String {
        switch kind {
        case .builtInMic: "iphone"
        case .headsetMic: "headphones"
        case .usb: "cable.connector"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .other: "mic"
        }
    }
}

/// One interface channel: on/off, its name and a live meter.
private struct ChannelRow: View {
    let model: RecordModel
    let channel: RecordModel.Channel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                TextField(
                    text: Binding(get: { channel.name }, set: { model.renameChannel(channel.index, to: $0) }),
                    prompt: Text(RecordModel.defaultName(ofChannel: channel.index))
                ) {
                    Text("Name of \(RecordModel.defaultName(ofChannel: channel.index))", comment: "VoiceOver label of a channel's name field, e.g. Name of Channel 2.")
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.token(.textPrimary))
                .submitLabel(.done)
                Toggle(isOn: Binding(get: { channel.isOn }, set: { model.setChannel(channel.index, isOn: $0) })) {
                    Text("Record \(RecordModel.defaultName(ofChannel: channel.index))", comment: "VoiceOver label of a channel's switch, e.g. Record Channel 2.")
                }
                .labelsHidden()
                .tint(.token(.success))
            }
            LevelMeter(level: model.level(of: channel), height: 6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

#if DEBUG
#Preview("Interface") {
    let model = previewRecordModel()
    Color.token(.ground)
        .sheet(isPresented: .constant(true)) { InputSheet(model: model) }
        .task { await model.appear() }
        .preferredColorScheme(.dark)
}

#Preview("Built-in") {
    let model = previewRecordModel(peaks: [0.4], inputs: [PreviewInputs.builtIn, PreviewInputs.airPods])
    Color.token(.ground)
        .sheet(isPresented: .constant(true)) { InputSheet(model: model) }
        .task { await model.appear() }
}
#endif
