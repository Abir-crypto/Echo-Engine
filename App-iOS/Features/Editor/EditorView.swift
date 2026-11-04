import EchoCore
import SwiftUI
#if DEBUG
import EchoCoreFakes
#endif

/// Creates the editor model once per opened project.
struct EditorScreen: View {
    let stored: StoredProject
    @Environment(AppContainer.self) private var container
    @State private var model: EditorModel?

    var body: some View {
        if let model {
            EditorView(model: model)
        } else {
            Color.token(.ground)
                .ignoresSafeArea()
                .task { model = container.makeEditorModel(for: stored) }
        }
    }
}

/// One editor for audio and video projects; only the header differs (SPEC § 9, mockups `Design/screens/Editor*.dc.html`).
struct EditorView: View {
    let model: EditorModel

    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTint) private var tint
    @Environment(\.deviceFamily) private var deviceFamily
    @State private var visibleDuration: Double = 20
    @State private var isRenaming = false
    @State private var adjustSheet: AdjustSheet?
    @State private var enhanceSheet: EnhanceSheet?
    @State private var newTitle = ""
    @State private var export: ExportModel?
    @State private var isSavingPreset = false
    @State private var presetName = ""

    var body: some View {
        Group {
            if case .needsSpaceToEdit(let bytes) = model.readiness {
                needsSpace(bytes)
            } else {
                editor
            }
        }
        // Content keeps the app tint; the TextValue tint below is only for the navigation bar.
        .tint(tint.text)
        .background(Color.token(.ground).ignoresSafeArea())
        .crashReportScreen("editor")
        .navigationTitle(model.project.title)
        .navigationBarTitleDisplayMode(.inline)
        // The editor is a full screen in the mockups: no tab bar.
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    newTitle = model.project.title
                    isRenaming = true
                } label: {
                    VStack(spacing: 0) {
                        Text(model.project.title)
                            .font(.headline)
                            .foregroundStyle(.token(.textPrimary))
                            .lineLimit(1)
                        basedOn
                            .font(.caption)
                            .foregroundStyle(.token(.textSecondary))
                            .lineLimit(1)
                    }
                }
                .disabled(!model.canEdit)
                .accessibilityHint(Text("Rename"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Export") { export = container.makeExportModel(for: model) }
                    .buttonStyle(.compactPrimary)
                    .disabled(!model.canEdit)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        // The native back chevron is a circle-button glyph: TextValue, not the tint (SPEC § 18.4). Alerts are attached
        // outside it, so their text buttons keep the app tint.
        .tint(.token(.textValue))
        .sheet(item: $export) { export in
            ExportSheet(model: export, presenter: container.deliveryPresenter) { closesEditor in
                self.export = nil
                // After "Keep, clear cache" or "Delete project" the editor is already closed: back to Projects.
                if closesEditor { dismiss() }
            }
        }
        .alert("Save as preset", isPresented: $isSavingPreset) {
            TextField("Name", text: $presetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { Task { await model.saveAsPreset(named: presetName) } }
        } message: {
            Text("Saves the enhancements, adjustments and loudness, not the trim.")
        }
        .alert("Rename project", isPresented: $isRenaming) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.rename(to: newTitle) }
        }
        .alert(isPresented: isPresented(failureBinding), error: model.failure.map(EditorFailureMessage.init)) {
            Button("OK") {}
        }
        .task {
            await model.open()
            visibleDuration = min(20, max(model.engine.duration, DetailWaveform.minimumVisibleDuration))
            #if DEBUG
            if UserDefaults.standard.bool(forKey: DebugAutoplay.launchArgument) { model.togglePlayback() }
            if UserDefaults.standard.bool(forKey: DebugManualDemo.launchArgument) { model.adjust(DebugManualDemo.apply) }
            if UserDefaults.standard.bool(forKey: DebugAIDemo.launchArgument), model.aiStack.isEmpty {
                model.addEnhancement(.noiseSuppression)
                model.addEnhancement(.clearVoice)
            }
            if let target = UserDefaults.standard.string(forKey: DebugLoudness.launchArgument).flatMap(DebugLoudness.target) {
                model.setOutputLoudness(target)
            }
            switch UserDefaults.standard.string(forKey: DebugEnhanceSheet.launchArgument) {
            case "add": enhanceSheet = .add
            case "strength": enhanceSheet = .strength(0)
            case "presets": enhanceSheet = .presets
            default: break
            }
            adjustSheet = UserDefaults.standard.string(forKey: DebugAdjustSheet.launchArgument).flatMap(AdjustSheet.init)
            if UserDefaults.standard.bool(forKey: DebugExportSheet.launchArgument) { export = container.makeExportModel(for: model) }
            #endif
        }
        .flushesAutosave(model.autosaver)
        .onDisappear {
            Task { await model.close() }
        }
    }

    /// "Based on: <preset>", with "(modified)" once the settings differ (SPEC § 9).
    @ViewBuilder private var basedOn: some View {
        if let preset = model.basePreset {
            if model.isModifiedFromBasePreset {
                Text("Based on: \(preset.displayName) (modified)")
            } else {
                Text("Based on: \(preset.displayName)")
            }
        }
    }

    private var editor: some View {
        ScrollView {
            VStack(spacing: 18) {
                if model.isReadOnly {
                    readOnlyBanner
                }
                header
                TransportRow(
                    isPlaying: model.engine.isPlaying,
                    canUndo: model.canUndo,
                    canRedo: model.canRedo,
                    onTogglePlay: model.togglePlayback,
                    onUndo: model.undo,
                    onRedo: model.redo,
                    onHoldOriginal: model.holdOriginal
                )
                // Read-only: all controls disabled, playback included (SPEC § 9).
                .disabled(!model.canEdit)
                overview
                    .disabled(!model.canEdit)
                EnhanceSection(
                    model: model,
                    onEditStrength: { enhanceSheet = .strength($0) },
                    onAdd: { enhanceSheet = .add },
                    onApplyPreset: { enhanceSheet = .presets },
                    onSaveAsPreset: {
                        presetName = ""
                        isSavingPreset = true
                    }
                )
                .padding(.top, 4)
                AdjustSection(model: model) { sheet in
                    adjustSheet = sheet
                    model.didOpenManualControl(sheet.group)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $enhanceSheet) { sheet in
            switch sheet {
            case .add: AddEnhancementSheet(model: model)
            case .strength(let index): StrengthSheet(model: model, index: index)
            case .presets: ApplyPresetSheet(model: model)
            }
        }
        .sheet(item: $adjustSheet) { sheet in
            switch sheet {
            case .equalizer: EqualizerSheet(model: model)
            case .gainDynamics: GainDynamicsSheet(model: model)
            case .effects: EffectsSheet(model: model)
            case .loudness: LoudnessSheet(model: model)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if model.isVideo {
            VideoPreview(player: model.engine.videoPlayer)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.token(.videoWell))
                .clipShape(.rect(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.token(.videoWellStroke)))
                .accessibilityElement()
                .accessibilityLabel(Text("Video preview"))
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !model.engine.isPlaying)) { _ in
                DetailWaveform(
                    original: model.peaks,
                    processed: model.renderedPeaks ?? (model.project.isProcessed ? model.peaks : nil),
                    peakLevel: model.peakLevel,
                    currentTime: model.engine.currentTime,
                    duration: model.engine.duration,
                    visibleDuration: $visibleDuration,
                    onScrub: model.seek
                )
            }
            .disabled(!model.canEdit)
        }
    }

    private var overview: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !model.engine.isPlaying)) { _ in
            let time = model.engine.currentTime
            VStack(spacing: 6) {
                OverviewStrip(
                    peaks: model.peaks,
                    peakLevel: model.peakLevel,
                    duration: model.sourceDuration,
                    trim: model.project.trimRange,
                    currentTime: time,
                    isProcessed: model.project.isProcessed,
                    isEditable: model.canEdit,
                    height: model.isVideo ? 68 : 52,
                    onSeek: model.seek,
                    onTrimStart: model.moveTrimStart,
                    onTrimEnd: model.moveTrimEnd,
                    onTrimEnded: model.finishTrim
                )
                HStack {
                    Text(DisplayFormat.duration(time))
                    Spacer()
                    if model.isTrimmed {
                        Text("Trimmed to \(DisplayFormat.duration(model.project.trimRange.duration)) of \(DisplayFormat.duration(model.sourceDuration))")
                    } else {
                        Text(DisplayFormat.duration(model.sourceDuration))
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.token(.textSecondary))
                .environment(\.layoutDirection, .leftToRight)
            }
        }
    }

    private var readOnlyBanner: some View {
        Label("Update Echo Engine to edit this project.", systemImage: "exclamationmark.circle")
            .font(.subheadline)
            .foregroundStyle(.token(.textValue))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.token(.surface), in: .rect(cornerRadius: 14))
    }

    /// SPEC § 9: blocked until there is room for the renders.
    private func needsSpace(_ bytes: Int64) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.token(.warning))
                .accessibilityHidden(true)
            Group {
                if deviceFamily == .pad {
                    Text("Need \(DisplayFormat.fileSize(bytes)) more to edit this project. Free up space on your iPad, then come back. Your import is saved.")
                } else {
                    Text("Need \(DisplayFormat.fileSize(bytes)) more to edit this project. Free up space on your iPhone, then come back. Your import is saved.")
                }
            }
            .font(.body)
            .foregroundStyle(.token(.textSecondary))
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var failureBinding: Binding<EditorModel.Failure?> {
        Binding(get: { model.failure }, set: { model.failure = $0 })
    }

    private func isPresented<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

/// The Enhance section's sheets (SPEC § 9).
private enum EnhanceSheet: Identifiable, Hashable {
    case add
    case strength(Int)
    case presets

    var id: Self { self }
}

/// What happened and what to do; never apologizes (SPEC § 4.7).
private struct EditorFailureMessage: LocalizedError {
    let failure: EditorModel.Failure

    var errorDescription: String? {
        switch failure {
        case .cantPlay: String(localized: "This project’s audio can’t be played. Import the file again to make a new project.")
        case .cantSave: String(localized: "Changes couldn’t be saved. Free up some space, then try again.")
        case .cantRender: String(localized: "An enhancement couldn’t be applied. Free up some space, then try again.")
        case .cantSavePreset: String(localized: "The preset couldn’t be saved. Free up some space, then try again.")
        case .cantSwitchRecording: String(localized: "The other recording couldn’t be used. Free up some space, then try again.")
        }
    }
}

#if DEBUG
@MainActor
private func previewEditor(_ project: Project, readOnly: Bool = false, available: Int64 = .max) -> some View {
    let levels = (0..<2_000).map { Float(0.2 + 0.6 * abs(sin(Double($0) / 37))) }
    let peaks = WaveformPeaks(sampleRate: 48_000, sourceFrameCount: Int64(levels.count * 256), peaks: levels)
    let model = EditorModel(
        stored: StoredProject(project: project, isReadOnly: readOnly),
        engine: FakePlaybackEngine(duration: project.sourceInfo.duration),
        repository: FakeProjectRepository(projects: [project]),
        waveforms: FakeWaveformProvider(peaks: peaks),
        devices: FakeAudioDeviceManager(),
        storage: FakeStorageEstimator(editBytes: 1_000, available: available),
        entitlements: FakeEntitlements(),
        capabilities: FakeCapabilities(),
        renderer: FakeAIChainRenderer(),
        janitor: FakeRenderCacheJanitor(),
        autoLevel: FakeAutoLevelAnalyzer(),
        presets: FakePresetRepository(),
        clock: FakeClock(),
        makeAutosaver: { _ in FakeProjectAutosaver() }
    )
    return NavigationStack { EditorView(model: model) }
}

#Preview("Audio, dark") {
    previewEditor(PreviewProjects.all()[1]).preferredColorScheme(.dark)
}

#Preview("Video, light") {
    previewEditor(PreviewProjects.all()[0]).preferredColorScheme(.light)
}

#Preview("Read-only, Arabic RTL, XXL") {
    previewEditor(PreviewProjects.all()[3], readOnly: true)
        .environment(\.locale, Locale(identifier: "ar"))
        .environment(\.layoutDirection, .rightToLeft)
        .dynamicTypeSize(.xxxLarge)
}

#Preview("Needs space") {
    previewEditor(PreviewProjects.all()[2], available: 0)
}

#Preview("Needs space, iPad") {
    previewEditor(PreviewProjects.all()[2], available: 0)
        .environment(\.deviceFamily, .pad)
}
#endif
