import EchoCore
import Foundation
import Observation

/// Editor state (SPEC § 9). The in-memory `project` is the source of truth while editing; every change is saved
/// through the autosaver (SPEC § 5.3).
@MainActor
@Observable
final class EditorModel {
    /// The trim keeps at least this much between its handles (SPEC § 9).
    static let minimumTrimDuration: Double = 1
    /// A new AI step's strength (user decision, SPEC § 9).
    static let newStepStrength: Float = 0.8
    /// Features offered in Add enhancement (SPEC § 7, § 9).
    static let offeredFeatures: [AIFeature] = [.noiseSuppression, .clearVoice, .voiceLeveler]

    enum Failure: Equatable {
        /// `working.caf` can't be loaded or the session can't play.
        case cantPlay
        case cantSave
        /// An AI step couldn't be rendered.
        case cantRender
        case cantSavePreset
    }

    private(set) var project: Project
    let isReadOnly: Bool
    private(set) var readiness: ProjectReadiness = .ready
    private(set) var isLoaded = false
    /// Waveform of `working.caf`; `nil` until loaded.
    private(set) var peaks: WaveformPeaks?
    /// The loudest peak, so waveforms can be drawn relative to it.
    private(set) var peakLevel: Float = 1
    /// While held, playback compares with the original: manual chain bypassed (F05); the AI render too (F06).
    private(set) var isHoldingOriginal = false
    /// Undo/redo of `EditState` snapshots (SPEC § 6.5).
    private(set) var history = EditHistory()
    /// The AI stack's latest render; `nil` until rendered.
    private(set) var rendered: RenderedChain?
    /// The AI step rendering now (its row shows progress, SPEC § 9), else `nil`.
    private(set) var renderingStep: Int?
    /// 0…1 within `renderingStep` (playback continues on the previous result meanwhile, SPEC § 6.3).
    private(set) var renderProgress: Double?
    /// Per-step A/B (SPEC § 6.6): the stack row heard on its own, or `nil` for the whole stack.
    private(set) var auditionedStep: Int?
    /// Waveform after the AI stack (its last render); `nil` without AI steps.
    private(set) var renderedPeaks: WaveformPeaks?
    /// Auto Level's current gain in dB (SPEC § 6.7); `nil` while the target is Off or before it's measured.
    private(set) var autoLevelGainDB: Double?
    /// Built-in and user presets (SPEC § 12), loaded when the editor opens.
    private(set) var presets: [Preset] = []
    var failure: Failure?

    let engine: any PlaybackEngine
    @ObservationIgnored let autosaver: any ProjectAutosaving
    @ObservationIgnored private let repository: any ProjectRepository
    @ObservationIgnored private let waveforms: any WaveformProviding
    @ObservationIgnored private let devices: any AudioDeviceManaging
    @ObservationIgnored private let storage: any StorageEstimating
    @ObservationIgnored private let entitlements: any EntitlementProvider
    @ObservationIgnored private let capabilities: any DeviceCapabilityChecking
    @ObservationIgnored private let autoLevel: any AutoLevelAnalyzing
    @ObservationIgnored private let presetRepository: any PresetRepository
    @ObservationIgnored private let clock: any DateProviding
    /// Auto Level waits this long after the last change before measuring (SPEC § 6.7: 500 ms).
    @ObservationIgnored private let autoLevelDelay: Duration
    @ObservationIgnored private var autoLevelTask: Task<Void, Never>?
    @ObservationIgnored private let renderer: any AIChainRendering
    @ObservationIgnored private let janitor: any RenderCacheJanitoring
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    /// The chain `rendered` belongs to; an export only starts from the current one.
    @ObservationIgnored private var renderedChain: AIChain?
    /// Counts render requests, so progress and results of superseded ones are ignored.
    @ObservationIgnored private var renderRequest = 0
    /// The audio the engine plays now.
    @ObservationIgnored private var playingAudio: URL?
    /// Saves are queued in order so the newest snapshot is always scheduled last.
    @ObservationIgnored private var lastSave: Task<Void, Never>?
    /// The edit state as of the last undo step; a commit records it before moving on.
    @ObservationIgnored private var committedState: EditState
    /// Pauses playback on interruptions and lost outputs while the editor is open.
    @ObservationIgnored private var sessionEvents: Task<Void, Never>?

    init(
        stored: StoredProject,
        engine: any PlaybackEngine,
        repository: any ProjectRepository,
        waveforms: any WaveformProviding,
        devices: any AudioDeviceManaging,
        storage: any StorageEstimating,
        entitlements: any EntitlementProvider,
        capabilities: any DeviceCapabilityChecking,
        renderer: any AIChainRendering,
        janitor: any RenderCacheJanitoring,
        autoLevel: any AutoLevelAnalyzing,
        presets: any PresetRepository,
        clock: any DateProviding,
        autoLevelDelay: Duration = .milliseconds(500),
        makeAutosaver: (@escaping @Sendable (any Error) -> Void) -> any ProjectAutosaving
    ) {
        project = stored.project
        isReadOnly = stored.isReadOnly
        committedState = stored.project.editState
        self.engine = engine
        self.repository = repository
        self.waveforms = waveforms
        self.devices = devices
        self.storage = storage
        self.entitlements = entitlements
        self.capabilities = capabilities
        self.renderer = renderer
        self.janitor = janitor
        self.autoLevel = autoLevel
        self.presetRepository = presets
        self.clock = clock
        self.autoLevelDelay = autoLevelDelay
        let failed = SaveFailureRelay()
        autosaver = makeAutosaver { _ in failed.report() }
        failed.onFailure = { [weak self] in self?.failure = .cantSave }
    }

    var isVideo: Bool { project.mediaType == .video }
    var canEdit: Bool { isLoaded && !isReadOnly }
    var canUndo: Bool { canEdit && history.canUndo }
    var canRedo: Bool { canEdit && history.canRedo }
    var sourceDuration: Double { project.sourceInfo.duration }
    /// The live manual chain (SPEC § 8).
    var manual: ManualSettings { project.editState.manual }
    /// The clip's AI stack, in processing order (SPEC § 7).
    var aiStack: [AIOperation] { project.editState.aiStack }
    /// Auto Level's loudness target; `nil` is Off (SPEC § 6.7).
    var outputLoudness: LoudnessTarget? { project.editState.outputLoudness }

    private var workingAudio: URL { repository.folder(for: project.id).working }

    private var chain: AIChain {
        AIChain(projectID: project.id, sourceRange: project.clips[0].sourceRange, operations: aiStack)
    }

    var isTrimmed: Bool {
        project.trimRange.start > 0.01 || project.trimRange.end < sourceDuration - 0.01
    }

    func open() async {
        guard !isLoaded else { return }
        if let available = try? storage.availableBytes() {
            readiness = storage.readiness(of: project, availableBytes: available)
        }
        if case .needsSpaceToEdit = readiness { return }
        let folder = repository.folder(for: project.id)
        do {
            try engine.load(audio: folder.working, video: isVideo ? folder.source(fileName: project.sourceFileName) : nil)
            engine.playbackRange = project.trimRange
            engine.apply(project.editState.manual)
            playingAudio = folder.working
            isLoaded = true
            followSessionEvents()
            renderChain()
        } catch {
            failure = .cantPlay
            return
        }
        await reloadPresets()
        if let peaks = try? await waveforms.peaks(of: folder.working, projectID: project.id, key: "working", progress: { _ in }) {
            self.peaks = peaks
            peakLevel = max(peaks.peaks.max() ?? 1, 0.001)
        }
    }

    /// Leaving the editor: stop playback and write pending changes.
    func close() async {
        sessionEvents?.cancel()
        sessionEvents = nil
        renderTask?.cancel()
        renderTask = nil
        autoLevelTask?.cancel()
        autoLevelTask = nil
        engine.pause()
        await lastSave?.value
        await autosaver.flush()
        // Only the current state's renders are needed once the history is gone (SPEC § 6.4).
        if isLoaded, !isReadOnly {
            try? await janitor.prune(projectID: project.id, sourceRange: project.clips[0].sourceRange, current: project.editState)
        }
    }

    // MARK: Export

    /// The audio an export starts from (SPEC § 11.2): the current AI stack's render, after the one in progress
    /// finishes (user decision, SPEC § 11.2), or `working.caf` without AI steps. Throws `ExportError.unreadableAudio`
    /// when the current stack has no render (it failed).
    func audioForExport() async throws -> URL {
        while let task = renderTask {
            await task.value
            try Task.checkCancellation()
            // A finished render clears `renderTask`; a newer one replaces it. Anything else would wait forever.
            guard renderTask != task else { break }
        }
        guard let rendered, renderedChain == chain else { throw ExportError.unreadableAudio }
        return rendered.output
    }

    func pausePlayback() {
        engine.pause()
    }

    /// Read-only projects play nothing either: all controls are disabled (SPEC § 9).
    func togglePlayback() {
        guard canEdit else { return }
        if engine.isPlaying {
            engine.pause()
            return
        }
        do {
            try devices.activateForPlayback()
            try engine.play()
        } catch {
            failure = .cantPlay
        }
    }

    func seek(to time: Double) {
        guard canEdit else { return }
        engine.seek(to: time)
    }

    /// While held, playback is `working.caf` with the manual chain bypassed (SPEC § 6.6).
    func holdOriginal(_ isHolding: Bool) {
        let isHolding = isHolding && canEdit
        guard isHolding != isHoldingOriginal else { return }
        isHoldingOriginal = isHolding
        engine.holdOriginal(isHolding)
        playCurrentSource()
    }

    /// Per-step A/B (SPEC § 6.6): plays the stack up to `step` alone; the same step again returns to the whole stack.
    func audition(step: Int) {
        guard aiStack.indices.contains(step) else { return }
        auditionedStep = auditionedStep == step ? nil : step
        playCurrentSource()
    }

    /// Whether this device and plan allow `feature` (SPEC § 4.8; always in v1).
    func isAvailable(_ feature: AIFeature) -> Bool {
        guard let gate = feature.gatedFeature else { return false }
        return entitlements.isUnlocked(gate) && capabilities.supports(gate)
    }

    /// Each feature appears once in the stack (user decision, SPEC § 9).
    func canAdd(_ feature: AIFeature) -> Bool {
        canEdit && isAvailable(feature) && !aiStack.contains { $0.kind == feature }
    }

    /// Adds `feature` at the end of the stack (it runs last), at 80 %.
    func addEnhancement(_ feature: AIFeature) {
        guard canAdd(feature) else { return }
        changeAIStack { $0.append(AIOperation(kind: feature, strength: Self.newStepStrength)) }
    }

    func removeEnhancement(at index: Int) {
        guard aiStack.indices.contains(index) else { return }
        changeAIStack { $0.remove(at: index) }
    }

    func moveEnhancements(fromOffsets source: IndexSet, toOffset destination: Int) {
        changeAIStack { $0.move(fromOffsets: source, toOffset: destination) }
    }

    /// Sets a step's strength (0…1) when its slider is released: one undo step and one render.
    func setStrength(_ strength: Float, at index: Int) {
        guard aiStack.indices.contains(index) else { return }
        changeAIStack { $0[index].strength = min(max(strength, 0), 1) }
    }

    /// Clear Voice already runs noise suppression; with Noise Suppression in the stack too, its row says so (never
    /// blocked, SPEC § 7).
    func showsAlreadyReducesNoise(at index: Int) -> Bool {
        aiStack.indices.contains(index) && aiStack[index].kind == .clearVoice && aiStack.contains { $0.kind == .noiseSuppression }
    }

    /// Changes the AI stack as one undo step, saves it and renders it; playback continues on the previous result
    /// until the render is ready (SPEC § 6.3).
    func changeAIStack(_ change: (inout [AIOperation]) -> Void) {
        guard canEdit else { return }
        var state = project.editState
        change(&state.aiStack)
        guard state.aiStack != aiStack else { return }
        project.editState = state
        auditionedStep = nil
        commit()
        renderChain()
    }

    /// Moves the trim start, keeping the end and at least `minimumTrimDuration` (or the whole source when shorter).
    func moveTrimStart(to time: Double) {
        guard canEdit else { return }
        let end = project.trimRange.end
        let start = min(max(time, 0), max(0, end - Self.minimumTrimDuration))
        applyTrim(TimeRangeCodable(start: start, duration: end - start))
    }

    func moveTrimEnd(to time: Double) {
        guard canEdit else { return }
        let start = project.trimRange.start
        let end = max(min(time, sourceDuration), min(sourceDuration, start + Self.minimumTrimDuration))
        applyTrim(TimeRangeCodable(start: start, duration: end - start))
    }

    /// A trim drag ended: one undo step, saved (SPEC § 6.5: undo registers on drag end, not per value).
    func finishTrim() {
        engine.playbackRange = project.trimRange
        let trimChanged = project.editState.trimRange != committedState.trimRange
        commit()
        if trimChanged { scheduleAutoLevel() }
    }

    func undo() {
        guard canEdit, let previous = history.undo(from: project.editState) else { return }
        restore(previous)
    }

    func redo() {
        guard canEdit, let next = history.redo(from: project.editState) else { return }
        restore(next)
    }

    /// Changes the manual chain and hears it at once (the chain ramps). Slider drags call this per step and
    /// `finishAdjusting` once at the end.
    func adjust(_ change: (inout ManualSettings) -> Void) {
        guard canEdit else { return }
        var state = project.editState
        change(&state.manual)
        guard state.manual != project.editState.manual else { return }
        project.editState = state
        engine.apply(state.manual)
        scheduleAutoLevel()
    }

    /// Sets the Auto Level target (`nil` = Off) as one undo step.
    func setOutputLoudness(_ target: LoudnessTarget?) {
        guard canEdit, target != outputLoudness else { return }
        var state = project.editState
        state.outputLoudness = target
        project.editState = state
        commit()
        scheduleAutoLevel()
    }

    /// A slider drag or toggle ended: one undo step, saved (SPEC § 6.5).
    func finishAdjusting() {
        commit()
    }

    /// Back to a flat equalizer, as one undo step.
    func resetEqualizer() {
        adjust { $0.eq = EQBand.defaultBands }
        commit()
    }

    // MARK: Presets

    /// The preset the project was last set from (`basePresetID`), while it still exists.
    var basePreset: Preset? {
        project.basePresetID.flatMap { id in presets.first { $0.id == id } }
    }

    /// The editor's subtitle says "(modified)" once the settings differ from the base preset (SPEC § 9).
    var isModifiedFromBasePreset: Bool {
        guard let preset = basePreset else { return false }
        let state = project.editState
        let sameStack = state.aiStack.count == preset.aiStack.count
            && zip(state.aiStack, preset.aiStack).allSatisfy { $0.kind == $1.kind && $0.strength == $1.strength }
        return !(sameStack && state.manual == preset.manual && state.outputLoudness == preset.outputLoudness)
    }

    /// "Update preset" is only for the person's own presets (SPEC § 9).
    var canUpdateBasePreset: Bool {
        canEdit && basePreset.map { !$0.isBuiltIn && !$0.isFromNewerVersion } == true
    }

    func reloadPresets() async {
        if let listed = try? await presetRepository.list() { presets = listed }
    }

    /// Replaces the AI stack, manual chain and Auto Level target with the preset's (copies, not linked; never the
    /// trim) as one undo step, and bases the project on it (SPEC § 9, § 12).
    func applyPreset(_ preset: Preset) {
        guard canEdit else { return }
        var state = project.editState
        state.aiStack = preset.aiStack.map { $0.renewed() }
        state.manual = preset.manual
        state.outputLoudness = preset.outputLoudness
        project.editState = state
        project.basePresetID = preset.id
        auditionedStep = nil
        engine.apply(state.manual)
        commit()
        // `basePresetID` isn't part of the undo state; save it even when the settings were already the preset's.
        save()
        renderChain()
    }

    /// A new user preset from the current settings; the project is then based on it.
    func saveAsPreset(named name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEdit, !name.isEmpty else { return }
        let state = project.editState
        let preset = Preset(
            name: name, aiStack: state.aiStack.map { $0.renewed() }, manual: state.manual,
            outputLoudness: state.outputLoudness, createdAt: clock.now
        )
        do {
            try await presetRepository.save(preset)
        } catch {
            failure = .cantSavePreset
            return
        }
        project.basePresetID = preset.id
        save()
        await reloadPresets()
    }

    /// Writes the current settings into the base user preset.
    func updateBasePreset() async {
        guard canUpdateBasePreset, var preset = basePreset else { return }
        let state = project.editState
        preset.aiStack = state.aiStack.map { $0.renewed() }
        preset.manual = state.manual
        preset.outputLoudness = state.outputLoudness
        preset.updatedAt = clock.now
        do {
            try await presetRepository.save(preset)
        } catch {
            failure = .cantSavePreset
            return
        }
        await reloadPresets()
    }

    /// Ignores titles that are empty after trimming whitespace.
    func rename(to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEdit, !title.isEmpty, title != project.title else { return }
        project.title = title
        save()
    }

    /// A call or a lost output pauses playback with the playhead kept; nothing resumes on its own, the next Play
    /// restarts the engine.
    private func followSessionEvents() {
        let events = devices.sessionEvents()
        sessionEvents = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .interruptionBegan, .outputDeviceRemoved: self.engine.pause()
                case .interruptionEnded: break
                }
            }
        }
    }

    private func applyTrim(_ range: TimeRangeCodable) {
        project.trimRange = range
        // A playing engine restarts its audio for a new range, which would stutter on every drag step, so it gets
        // the range when the drag ends.
        if !engine.isPlaying { engine.playbackRange = range }
    }

    /// Makes the current edit state an undo step if it changed since the last one, then saves.
    private func commit() {
        let current = project.editState
        guard current != committedState else { return }
        history.record(before: committedState)
        committedState = current
        save()
        sweepRenders()
    }

    private func restore(_ state: EditState) {
        let stackChanged = state.aiStack != aiStack
        project.editState = state
        committedState = state
        engine.playbackRange = state.trimRange
        engine.apply(state.manual)
        save()
        if stackChanged {
            auditionedStep = nil
            renderChain()
        } else {
            sweepRenders()
            scheduleAutoLevel()
        }
    }

    // MARK: Auto Level

    /// Measures the processed audio over the trim range once changes settle and sends the gain to the engine
    /// (SPEC § 6.7). While an AI render is in progress it waits for it.
    private func scheduleAutoLevel() {
        autoLevelTask?.cancel()
        autoLevelTask = nil
        guard isLoaded else { return }
        guard let target = outputLoudness else {
            autoLevelGainDB = nil
            engine.setAutoLevelGain(0)
            return
        }
        guard renderTask == nil, let audio = rendered?.output else { return }
        let manual = self.manual, range = project.trimRange, delay = autoLevelDelay
        autoLevelTask = Task { [weak self, autoLevel] in
            do {
                try await Task.sleep(for: delay)
                let gain = try await autoLevel.gain(of: audio, manual: manual, range: range, target: target)
                try Task.checkCancellation()
                guard let self else { return }
                self.autoLevelGainDB = gain
                self.engine.setAutoLevelGain(gain)
            } catch {
                // Cancelled by a newer change, or unmeasurable: the previous gain stays.
            }
        }
    }

    // MARK: AI renders

    /// Renders the AI stack (cached prefixes are instant) and swaps playback to it at the playhead when ready. A newer
    /// request supersedes this one (latest change wins, SPEC § 6.3).
    private func renderChain() {
        renderTask?.cancel()
        renderRequest += 1
        let request = renderRequest
        let chain = self.chain
        renderingStep = nil
        renderProgress = nil
        guard !chain.operations.isEmpty else {
            renderTask = nil
            rendered = RenderedChain(prefixes: [], output: workingAudio)
            renderedChain = chain
            renderedPeaks = nil
            playCurrentSource()
            sweepRenders()
            scheduleAutoLevel()
            return
        }
        let source = workingAudio
        let relay = RenderProgressRelay(model: self, request: request)
        renderTask = Task { [weak self, renderer] in
            do {
                let result = try await renderer.render(source: source, chain: chain, progress: relay.report)
                self?.renderFinished(result, chain: chain, request: request)
            } catch is CancellationError {
            } catch {
                guard let self, self.renderRequest == request else { return }
                self.renderTask = nil
                self.renderingStep = nil
                self.renderProgress = nil
                self.failure = .cantRender
            }
        }
    }

    fileprivate func renderProgressed(_ progress: ChainRenderProgress, request: Int) {
        guard request == renderRequest, renderTask != nil else { return }
        renderingStep = progress.step
        renderProgress = progress.fraction
    }

    private func renderFinished(_ result: RenderedChain, chain: AIChain, request: Int) {
        guard request == renderRequest else { return }
        renderTask = nil
        renderingStep = nil
        renderProgress = nil
        rendered = result
        renderedChain = chain
        if let step = auditionedStep, !result.prefixes.indices.contains(step) { auditionedStep = nil }
        playCurrentSource()
        sweepRenders()
        loadRenderedPeaks(of: result.output)
        scheduleAutoLevel()
    }

    /// Hold for original → `working.caf`; an auditioned step → its prefix render; otherwise the whole stack's render.
    private func playCurrentSource() {
        guard isLoaded else { return }
        let target = if isHoldingOriginal {
            workingAudio
        } else if let step = auditionedStep, let rendered, rendered.prefixes.indices.contains(step) {
            rendered.prefixes[step]
        } else {
            rendered?.output ?? workingAudio
        }
        guard target != playingAudio else { return }
        do {
            try engine.swapAudio(to: target)
            playingAudio = target
        } catch {
            failure = .cantPlay
        }
    }

    private func loadRenderedPeaks(of output: URL) {
        guard output != workingAudio else {
            renderedPeaks = nil
            return
        }
        let projectID = project.id
        guard let renderKey = RenderKey(hash: output.deletingPathExtension().lastPathComponent) else { return }
        Task { [weak self, waveforms] in
            let key = renderKey.waveformKey
            let peaks = try? await waveforms.peaks(of: output, projectID: projectID, key: key, progress: { _ in })
            guard let self, self.rendered?.output == output else { return }
            self.renderedPeaks = peaks
        }
    }

    /// Mark and sweep after any stack or history change (SPEC § 6.4).
    private func sweepRenders() {
        guard isLoaded, !isReadOnly else { return }
        let projectID = project.id, range = project.clips[0].sourceRange
        let current = project.editState, states = history.allStates
        Task { [janitor] in
            try? await janitor.sweep(projectID: projectID, sourceRange: range, current: current, history: states)
        }
    }

    private func save() {
        guard !isReadOnly else { return }
        let snapshot = project
        let previous = lastSave
        lastSave = Task { [autosaver] in
            await previous?.value
            await autosaver.schedule(snapshot)
        }
    }
}

/// Carries autosave failures (reported off the main actor) back to the model.
@MainActor
private final class SaveFailureRelay {
    var onFailure: (() -> Void)?

    nonisolated func report() {
        Task { @MainActor in self.onFailure?() }
    }
}

/// Carries render progress (reported off the main actor) back to the model, for one render request.
@MainActor
private final class RenderProgressRelay {
    private weak var model: EditorModel?
    private let request: Int

    init(model: EditorModel, request: Int) {
        self.model = model
        self.request = request
    }

    nonisolated func report(_ progress: ChainRenderProgress) {
        Task { @MainActor in self.model?.renderProgressed(progress, request: self.request) }
    }
}
