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

    @Environment(\.appTint) private var tint
    @Environment(\.deviceFamily) private var deviceFamily
    @State private var visibleDuration: Double = 20
    @State private var isRenaming = false
    @State private var adjustSheet: AdjustSheet?
    @State private var newTitle = ""

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
                    Text(model.project.title)
                        .font(.headline)
                        .foregroundStyle(.token(.textPrimary))
                        .lineLimit(1)
                }
                .disabled(!model.canEdit)
                .accessibilityHint(Text("Rename"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Export arrives in F08.
                Button("Export") {}
                    .buttonStyle(.compactPrimary)
                    .disabled(true)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        // The native back chevron is a circle-button glyph: TextValue, not the tint (SPEC § 18.4). Alerts are attached
        // outside it, so their text buttons keep the app tint.
        .tint(.token(.textValue))
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
            adjustSheet = UserDefaults.standard.string(forKey: DebugAdjustSheet.launchArgument).flatMap(AdjustSheet.init)
            #endif
        }
        .flushesAutosave(model.autosaver)
        .onDisappear {
            Task { await model.close() }
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
                AdjustSection(model: model) { adjustSheet = $0 }
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $adjustSheet) { sheet in
            switch sheet {
            case .equalizer: EqualizerSheet(model: model)
            case .gainDynamics: GainDynamicsSheet(model: model)
            case .effects: EffectsSheet(model: model)
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
                    processed: model.project.isProcessed ? model.peaks : nil,
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

/// What happened and what to do; never apologizes (SPEC § 4.7).
private struct EditorFailureMessage: LocalizedError {
    let failure: EditorModel.Failure

    var errorDescription: String? {
        switch failure {
        case .cantPlay: String(localized: "This project’s audio can’t be played. Import the file again to make a new project.")
        case .cantSave: String(localized: "Changes couldn’t be saved. Free up some space, then try again.")
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
