import EchoCore
import SwiftUI
import UIKit
#if DEBUG
import EchoCoreFakes
#endif

/// Record tab (SPEC § 13.1, mockup `Design/screens/Record.dc.html`): input pill, status and timer, a named meter per
/// recorded channel, the background message while a take is open, Pause and Record/Stop, and dim mode. Settings rows:
/// Noise reduction, Input gain and, with headphones, Monitor (SPEC § 13.4); Auto-tune and Backing track come with F12.
struct RecordView: View {
    let model: RecordModel

    @State private var sheet: RecordSheet?

    var body: some View {
        NavigationStack {
            ScrollView {
                if model.problem == .microphoneDenied {
                    MicrophoneDeniedView()
                } else {
                    recorder
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color.token(.ground).ignoresSafeArea())
            .navigationTitle("Record")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    inputButton
                }
            }
        }
        .task {
            await model.appear()
            #if DEBUG
            if let name = UserDefaults.standard.string(forKey: DebugRecordTab.sheetArgument) { sheet = RecordSheet(rawValue: name) }
            #endif
        }
        .onDisappear { model.disappear() }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .input: InputSheet(model: model)
            case .noiseReduction: NoiseReductionSheet(model: model)
            case .autoTune: AutoTuneSheet(model: model)
            case .inputGain: InputGainSheet(model: model)
            case .monitor: MonitorSheet(model: model)
            }
        }
        .fullScreenCover(isPresented: Binding(get: { model.isDimmed }, set: { model.isDimmed = $0 })) {
            DimRecordingView(model: model)
        }
        .alert(
            Text("Recording stopped", comment: "Alert title: the app ended the recording by itself."),
            isPresented: Binding(get: { model.stopNotice != nil }, set: { if !$0 { model.dismissNotice() } }),
            presenting: model.stopNotice
        ) { _ in
            Button {
                model.openNoticeProject()
            } label: {
                Text("Open recording", comment: "Opens the recording that was stopped and saved.")
            }
            Button("OK", role: .cancel) { model.dismissNotice() }
        } message: { reason in
            switch reason {
            case .lowStorage:
                Text(
                    "Less than \(DisplayFormat.fileSize(RecordingStoragePolicy.standard.stopBelow)) was free, so Echo Engine stopped and saved your recording.",
                    comment: "Why recording stopped: the device ran out of space; the size, e.g. 200 MB."
                )
            case .writeFailed:
                Text("The recording couldn’t be written any further. Everything up to then is saved.")
            }
        }
    }

    private var recorder: some View {
        VStack(spacing: 16) {
            RecordSettingsRows(model: model, open: { sheet = $0 })

            VStack(spacing: 6) {
                RecordingStatus(state: model.state, hasTake: model.hasTake)
                RecordingTimer(engine: model.engine)
            }
            .padding(.top, 18)

            ChannelMeters(model: model)
                .padding(.top, 4)

            if model.hasTake {
                Text("Recording continues if you leave the app. Calls or apps that use the microphone may pause it. Your audio so far is always saved.")
                    .font(.footnote)
                    .lineSpacing(2)
                    .foregroundStyle(.token(.textValue))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.token(.surface), in: .rect(cornerRadius: 12))
            }

            if let problem = model.problem {
                problemText(problem)
                    .font(.footnote)
                    .foregroundStyle(.token(.warning))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            RecordControls(model: model)
                .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private var inputButton: some View {
        Button {
            sheet = .input
        } label: {
            HStack(spacing: 6) {
                Text(model.selectedInput?.name ?? String(localized: "Input", comment: "Input device button before one is known."))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.semibold))
        }
        .tint(.token(.textValue))
        .disabled(!model.canChangeInput)
        .accessibilityLabel(Text("Input", comment: "Input device button before one is known."))
        .accessibilityValue(Text(model.selectedInput?.name ?? ""))
        .accessibilityHint(Text("Chooses the microphone and its channels.", comment: "VoiceOver hint of the input button."))
    }

    private func problemText(_ problem: RecordModel.Problem) -> Text {
        switch problem {
        case .microphoneDenied:
            Text(verbatim: "")
        case .noInput:
            Text("No microphone is available. Connect one to record.")
        case .notEnoughSpace(let available):
            Text(
                "Recording needs at least \(DisplayFormat.fileSize(RecordingStoragePolicy.standard.minimumToStart)) free. You have \(DisplayFormat.fileSize(available)).",
                comment: "Not enough space to start recording: the minimum and the free space, e.g. 500 MB and 320 MB."
            )
        case .cantStart:
            Text("Recording couldn’t start. Close other apps that use the microphone, then try again.")
        case .inputMissing(let name):
            Text(
                "Connect “\(name)” again to continue, or stop to save the recording.",
                comment: "The recorded input was disconnected; its name, e.g. USB interface."
            )
        case .microphoneBusy:
            Text("A call or another app is using the microphone. Resume when it’s finished.")
        case .cantSave:
            Text("This recording couldn’t be saved as a project. It stays on your device, and Echo Engine offers it again the next time it opens.")
        }
    }
}

/// Red dot and "Recording", or what holds the take (SPEC § 13.1, § 13.7).
struct RecordingStatus: View {
    let state: RecordingState
    let hasTake: Bool

    var body: some View {
        HStack(spacing: 8) {
            if state == .recording {
                Circle()
                    .fill(.token(.record))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(state == .recording ? .token(.warning) : .token(.textSecondary))
        }
        .frame(minHeight: 20)
    }

    private var label: Text {
        switch state {
        case .recording:
            Text("Recording", comment: "Live Activity status: the app is recording.")
        case .paused:
            Text("Paused", comment: "Live Activity status: the recording is paused.")
        case .pausedByInterruption(.interruption):
            Text("Paused by a call or another app")
        case .pausedByInterruption:
            Text("Paused: the input was disconnected")
        case .finishing, .ended:
            Text("Saving…")
        case .ready, .idle:
            hasTake ? Text(verbatim: "") : Text("Ready to record")
        }
    }
}

/// The take's time in large tabular digits (SPEC § 18.3: 68 pt light, monospaced), read from the engine on every frame.
struct RecordingTimer: View {
    let engine: any RecordingEngine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            Text(DisplayFormat.duration(engine.elapsedSeconds))
                .font(.system(size: 68, weight: .light))
                .monospacedDigit()
                .kerning(-1)
                .foregroundStyle(.token(.textPrimary))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityLabel(Text("Recorded time", comment: "VoiceOver label of the recording timer."))
        }
    }
}

/// A named meter per recorded channel, with its level in dB.
struct ChannelMeters: View {
    let model: RecordModel

    var body: some View {
        VStack(spacing: 14) {
            if model.recordedChannels.isEmpty, !model.channels.isEmpty {
                Text("Choose a channel to record in Input.")
                    .font(.footnote)
                    .foregroundStyle(.token(.textSecondary))
            }
            ForEach(model.recordedChannels) { channel in
                let level = model.level(of: channel)
                VStack(spacing: 6) {
                    HStack {
                        Text(channel.name.isEmpty ? RecordModel.defaultName(ofChannel: channel.index) : channel.name)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.token(.textPrimary))
                            .lineLimit(1)
                        Spacer()
                        Text(DisplayFormat.meterLevel(level))
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.token(.textSecondary))
                            .accessibilityHidden(true)
                    }
                    LevelMeter(level: level)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Pause/Resume, Record/Stop and dim mode (mockup: 52 pt circles beside the 80 pt ring).
private struct RecordControls: View {
    let model: RecordModel

    var body: some View {
        HStack(spacing: 36) {
            if model.hasTake {
                pauseButton
            } else {
                Color.clear.frame(width: 52, height: 52)
            }
            mainButton
            if model.hasTake {
                CircleButton(systemImage: "moon.fill", label: Text("Dim screen", comment: "Button: shows the minimal dark recording screen.")) {
                    model.isDimmed = true
                }
            } else {
                Color.clear.frame(width: 52, height: 52)
            }
        }
    }

    @ViewBuilder
    private var pauseButton: some View {
        if model.state == .recording {
            CircleButton(systemImage: "pause.fill", label: Text("Pause")) {
                model.pause()
            }
        } else {
            CircleButton(systemImage: "play.fill", label: Text("Resume", comment: "Continues a paused recording.")) {
                model.resume()
            }
            .disabled(!model.canResume || model.isFinishing)
        }
    }

    private var mainButton: some View {
        Button {
            Task {
                if model.hasTake { await model.stop() } else { await model.record() }
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.token(.textPrimary), lineWidth: 4)
                if model.hasTake {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.token(.record))
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(.token(.record))
                        .frame(width: 62, height: 62)
                }
            }
            .frame(width: 80, height: 80)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(model.hasTake ? model.isFinishing : !model.canRecord)
        .opacity(model.hasTake || model.canRecord ? 1 : 0.4)
        .accessibilityLabel(model.hasTake
            ? Text("Stop recording", comment: "Live Activity button and action: ends the recording.")
            : Text("Record"))
    }
}

/// A 52 pt `Surface` circle with a glyph (mockup Pause button).
private struct CircleButton: View {
    let systemImage: String
    let label: Text
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.token(.textPrimary))
                .frame(width: 52, height: 52)
                .background(.token(.surface), in: .circle)
                .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Without the microphone nothing can be recorded: says so and links to Settings.
private struct MicrophoneDeniedView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "mic.slash")
                .font(.system(size: 40))
                .foregroundStyle(.token(.iconMuted))
                .accessibilityHidden(true)
            Text("Allow the microphone")
                .font(.title3.bold())
                .foregroundStyle(.token(.textPrimary))
            Text("Echo Engine needs the microphone to record. Your recordings stay on your device.")
                .font(.subheadline)
                .foregroundStyle(.token(.textSecondary))
                .multilineTextAlignment(.center)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                Text("Open Settings")
            }
            .buttonStyle(.primary)
            .padding(.top, 8)
        }
        .padding(.horizontal, 20)
        .padding(.top, 80)
    }
}

#if DEBUG
@MainActor
func previewRecordModel(peaks: [Float] = [0.25, 0.12], inputs: [AudioInput] = PreviewInputs.interface) -> RecordModel {
    let devices = FakeAudioDeviceManager(inputs: inputs)
    let engine = FakeRecordingEngine(inputChannels: inputs.first?.channelCount ?? 1, peaks: peaks)
    return RecordModel(
        engine: engine, devices: devices, interruptions: RecordingInterruptions(devices: devices, engine: engine),
        projects: FakeProjectRepository(), builder: FakeRecordedProjectBuilder(), idleTimer: FakeIdleTimer(),
        activity: FakeRecordingActivity(), stopRelay: RecordingStopRelay(), settings: FakeAppSettingsStore(), clock: FakeClock(),
        title: { DisplayFormat.recordingTitle($0) }
    )
}

enum PreviewInputs {
    static let builtIn = AudioInput(id: "built-in", name: "iPhone Microphone", kind: .builtInMic, channelCount: 1, supportsStereo: true)
    static let usb = AudioInput(id: "usb", name: "USB interface", kind: .usb, channelCount: 2, supportsStereo: false)
    static let airPods = AudioInput(id: "airpods", name: "AirPods Pro", kind: .bluetooth, channelCount: 1, supportsStereo: false)
    static let interface = [usb, builtIn, airPods]
}

#Preview("Ready") {
    RecordView(model: previewRecordModel())
        .preferredColorScheme(.dark)
}

#Preview("Recording, light") {
    let model = previewRecordModel()
    RecordView(model: model)
        .task { await model.record() }
        .preferredColorScheme(.light)
}

#Preview("Arabic RTL, XXL") {
    RecordView(model: previewRecordModel())
        .environment(\.locale, Locale(identifier: "ar"))
        .environment(\.layoutDirection, .rightToLeft)
        .dynamicTypeSize(.xxxLarge)
}
#endif
