import EchoCore
import SwiftUI

/// The export sheet (SPEC § 11.1, mockup `Design/screens/Export.dc.html`): Export as, Audio quality, Save to, After
/// export, the storage line and one primary button; while exporting, progress with Cancel. Native segmented controls
/// replace the mockup's drawn ones (SPEC § 18.1).
struct ExportSheet: View {
    let model: ExportModel
    let presenter: DeliveryPresenter
    /// Once delivered and the post-export action is done; `closesEditor` after clearing the cache or deleting.
    let onFinish: (_ closesEditor: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isExporting {
                ExportProgressView(model: model)
            } else {
                ExportForm(model: model)
                    .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            }
        }
        .background(Color.token(.ground).ignoresSafeArea())
        .crashReportScreen("export")
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(model.isExporting)
        .presentsDeliveries(presenter)
        .task { await model.load() }
        .onChange(of: model.phase) { _, phase in
            if case .finished(let closesEditor) = phase, model.failure == nil { onFinish(closesEditor) }
        }
        .alert(isPresented: failureBinding, error: model.failure.map(ExportFailureMessage.init)) {
            if model.failure == .photosDenied, let settings = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { openURL(settings) }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK") { finishAfterAlert() }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Export")
                .font(.title2.bold())
                .foregroundStyle(.token(.textPrimary))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.token(.textValue))
                    .frame(width: 36, height: 36)
                    .background(.token(.surface), in: .circle)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
            .disabled(model.isExporting)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            storageLine
                .font(.footnote)
                .foregroundStyle(model.hasEnoughSpace ? .token(.textSecondary) : .token(.warning))
                .multilineTextAlignment(.center)
                .monospacedDigit()
            Button {
                model.start()
            } label: {
                switch model.primaryAction {
                case .exportVideo: Text("Export video")
                case .exportAudio: Text("Export audio")
                case .export: Text("Export")
                }
            }
            .buttonStyle(.primary)
            .disabled(!model.hasEnoughSpace)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color.token(.ground))
    }

    private var storageLine: Text {
        let needed = DisplayFormat.fileSize(model.neededBytes)
        guard let available = model.availableBytes else { return Text("Needs about \(needed).") }
        return Text("Needs about \(needed). \(DisplayFormat.fileSize(available)) available.")
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })
    }

    /// A failure after delivery (the project couldn't be deleted) is shown first, then the sheet closes.
    private func finishAfterAlert() {
        if case .finished(let closesEditor) = model.phase { onFinish(closesEditor) }
    }
}

/// The choices: Export as (video projects), Audio quality (+ Custom settings), Save to, After export.
private struct ExportForm: View {
    @Bindable var model: ExportModel

    @Environment(\.appTint) private var tint

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.offersExportKind {
                    section("Export as") {
                        Picker(selection: $model.choices.kind) {
                            Text("Video").tag(ExportKind.video)
                            Text("Audio only").tag(ExportKind.audioOnly)
                            Text("Both").tag(ExportKind.both)
                        } label: {
                            Text("Export as")
                        }
                        .pickerStyle(.segmented)
                    }
                }
                section("Audio quality") {
                    Picker(selection: $model.choices.quality) {
                        Text("Standard").tag(AudioQuality.standard)
                        // Its own key: the EQ's "High" (treble band) translates differently.
                        Text(String(localized: "export.quality.high", defaultValue: "High", comment: "Audio quality preset: AAC 320 kbps."))
                            .tag(AudioQuality.high)
                        Text("Lossless").tag(AudioQuality.lossless)
                        Text("Custom").tag(AudioQuality.custom)
                    } label: {
                        Text("Audio quality")
                    }
                    .pickerStyle(.segmented)
                    if model.choices.quality == .custom {
                        customSettings
                    }
                    QualityCaption(output: model.output)
                        .font(.footnote)
                        .foregroundStyle(.token(.textSecondary))
                }
                section("Save to") {
                    HStack(spacing: 10) {
                        tile(.photos, title: "Photos", symbol: "photo.on.rectangle")
                            .disabled(!model.offersPhotos)
                        tile(.files, title: "Files", symbol: "folder")
                        tile(.share, title: "Share", symbol: "square.and.arrow.up")
                    }
                }
                section("After export") {
                    GroupedRows {
                        afterExportRow(.keepProject, title: "Keep project", frees: nil)
                        RowSeparator()
                        afterExportRow(.keepProjectClearCache, title: "Keep, clear cache", frees: model.bytesFreedByClearingCache)
                        RowSeparator()
                        afterExportRow(.deleteProject, title: "Delete project", frees: model.bytesFreedByDeleting)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.token(.textSecondary))
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// Custom: a video's audio only has a bitrate; an audio file has a format, a sample rate and a bit depth or bitrate.
    @ViewBuilder private var customSettings: some View {
        if case .video = model.output {
            bitratePicker(Binding(
                get: { model.choices.videoAudioBitrate },
                set: { bitrate in
                    model.choices.custom.format = .aac
                    model.choices.custom.bitrate = bitrate
                }
            ))
        } else {
            labeled("Format") {
                Picker(selection: $model.choices.custom.format) {
                    ForEach(AudioFormat.allCases, id: \.self) { format in
                        Text(verbatim: format.displayName).tag(format)
                    }
                } label: {
                    Text("Format")
                }
                .pickerStyle(.segmented)
            }
            labeled("Sample rate") {
                Picker(selection: $model.choices.custom.sampleRate) {
                    ForEach(AudioExportSettings.sampleRates, id: \.self) { rate in
                        Text(verbatim: DisplayFormat.frequency(Float(rate))).tag(rate)
                    }
                } label: {
                    Text("Sample rate")
                }
                .pickerStyle(.segmented)
            }
            if model.choices.custom.format.isLossless {
                labeled("Bit depth") {
                    Picker(selection: Binding(get: { model.choices.custom.bitDepth ?? 24 }, set: { model.choices.custom.bitDepth = $0 })) {
                        ForEach(AudioExportSettings.bitDepths, id: \.self) { depth in
                            Text("\(depth)-bit").tag(depth)
                        }
                    } label: {
                        Text("Bit depth")
                    }
                    .pickerStyle(.segmented)
                }
            } else {
                bitratePicker(Binding(get: { model.choices.custom.bitrate ?? ExportChoices.defaultVideoAudioBitrate }, set: { model.choices.custom.bitrate = $0 }))
            }
        }
    }

    private func bitratePicker(_ selection: Binding<Int>) -> some View {
        labeled("Bitrate") {
            Picker(selection: selection) {
                ForEach(AudioExportSettings.aacBitrates, id: \.self) { bitrate in
                    Text("\(bitrate / 1_000) kbps").tag(bitrate)
                }
            } label: {
                Text("Bitrate")
            }
            .pickerStyle(.segmented)
        }
    }

    private func labeled(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.token(.textSecondary))
            content()
        }
    }

    /// A "Save to" tile; the selected one has a tint border.
    private func tile(_ kind: DestinationKind, title: LocalizedStringKey, symbol: String) -> some View {
        let isSelected = model.choices.destination == kind
        return Button {
            model.choices.destination = kind
        } label: {
            VStack(spacing: 6) {
                // Symbols differ in height; a fixed frame keeps the three labels on one line.
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(height: 28)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(isSelected ? .token(.textPrimary) : .token(.textSecondary))
            .frame(maxWidth: .infinity, minHeight: 68)
            .padding(.vertical, 6)
            .background(.token(.surface), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? tint.fill : Color.token(.separator), lineWidth: 1.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func afterExportRow(_ action: PostExportAction, title: LocalizedStringKey, frees bytes: Int64?) -> some View {
        let isSelected = model.postAction == action
        return Button {
            model.postAction = action
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(isSelected ? tint.fill : Color.token(.waveformIdle), lineWidth: isSelected ? 6 : 2)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.token(.textPrimary))
                Spacer(minLength: 8)
                if let bytes, bytes > 0 {
                    Text("Frees \(DisplayFormat.fileSize(bytes))")
                        .font(.footnote)
                        .foregroundStyle(.token(.textSecondary))
                        .monospacedDigit()
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
}

/// Explains the chosen quality, e.g. "AAC 320 kbps. The video is kept exactly as it is."
private struct QualityCaption: View {
    let output: ExportOutput

    var body: some View {
        switch output {
        case .video(let bitrate):
            Text("AAC \(Self.kbps(bitrate)) kbps. The video is kept exactly as it is.")
        case .audioOnly(let settings):
            Text(Self.describe(settings))
        case .both(let bitrate, let settings):
            Text("\(Self.describe(settings)) The video gets AAC \(Self.kbps(bitrate)) kbps and is kept exactly as it is.")
        }
    }

    private static func kbps(_ bitrate: Int) -> String {
        (bitrate / 1_000).formatted()
    }

    private static func describe(_ settings: AudioExportSettings) -> String {
        guard settings.format.isLossless else {
            return String(localized: "AAC \(kbps(settings.bitrate ?? ExportChoices.defaultVideoAudioBitrate)) kbps.", comment: "Export quality caption for an AAC audio file, e.g. AAC 320 kbps.")
        }
        let rate = DisplayFormat.frequency(Float(settings.sampleRate))
        return String(
            localized: "\(settings.format.displayName) \(settings.bitDepth ?? 24)-bit, \(rate).",
            comment: "Export quality caption for a lossless file: format, bit depth, sample rate, e.g. FLAC 24-bit, 48 kHz."
        )
    }
}

/// While exporting: what is happening, progress and Cancel.
private struct ExportProgressView: View {
    let model: ExportModel

    @Environment(\.appTint) private var tint

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            title
                .font(.headline)
                .foregroundStyle(.token(.textPrimary))
            if case .exporting(let fraction) = model.phase {
                ProgressView(value: fraction) {
                    EmptyView()
                } currentValueLabel: {
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                }
                .tint(tint.fill)
            } else {
                ProgressView()
            }
            if model.continuesInBackground {
                Text("The export continues if you leave Echo Engine.")
                    .font(.footnote)
                    .foregroundStyle(.token(.textSecondary))
                    .multilineTextAlignment(.center)
            }
            Button("Cancel", role: .cancel) { model.cancel() }
                .buttonStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var title: some View {
        switch model.phase {
        case .waitingForEnhancements: Text("Finishing enhancements…")
        case .delivering: Text("Saving…")
        default: Text("Exporting…")
        }
    }
}

extension AudioFormat {
    /// Codec names are the same in every language.
    var displayName: String {
        switch self {
        case .aac: "AAC"
        case .wav: "WAV"
        case .flac: "FLAC"
        case .alac: "ALAC"
        }
    }
}

private struct ExportFailureMessage: LocalizedError {
    let failure: ExportModel.Failure

    var errorDescription: String? {
        switch failure {
        case .notEnoughSpace(let needed, let available):
            String(localized: "This export needs about \(DisplayFormat.fileSize(needed)). You have \(DisplayFormat.fileSize(available)) free. Free up space, then try again.")
        case .enhancementsFailed:
            String(localized: "An enhancement couldn’t be applied, so there’s nothing to export yet. Free up some space, then try again.")
        case .couldNotExport:
            String(localized: "The export couldn’t be finished. Free up some space, then try again.")
        case .photosDenied:
            String(localized: "Echo Engine can’t add videos to your photo library. Allow it in Settings, then try again.")
        case .couldNotSave:
            String(localized: "The file couldn’t be saved there. Try again, or choose another place.")
        case .couldNotDelete:
            String(localized: "Your export is saved, but the project couldn’t be deleted. You can delete it in Projects.")
        case .stoppedInBackground:
            String(localized: "The export stopped before it finished. Try again, and keep Echo Engine open if it stops again.")
        }
    }
}
