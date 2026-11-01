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

    enum Failure: Equatable {
        /// `working.caf` can't be loaded or the session can't play.
        case cantPlay
        case cantSave
        /// An AI step couldn't be rendered.
        case cantRender
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
    /// 0…1 while AI steps render (playback continues on the previous result, SPEC § 6.3), else `nil`.
    private(set) var renderProgress: Double?
    /// Per-step A/B (SPEC § 6.6): the stack row heard on its own, or `nil` for the whole stack.
    private(set) var auditionedStep: Int?
    /// Waveform after the AI stack (its last render); `nil` without AI steps.
    private(set) var renderedPeaks: WaveformPeaks?
    var failure: Failure?

    let engine: any PlaybackEngine
    @ObservationIgnored let autosaver: any ProjectAutosaving
    @ObservationIgnored private let repository: any ProjectRepository
    @ObservationIgnored private let waveforms: any WaveformProviding
    @ObservationIgnored private let devices: any AudioDeviceManaging
    @ObservationIgnored private let storage: any StorageEstimating
    @ObservationIgnored private let renderer: any AIChainRendering
    @ObservationIgnored private let janitor: any RenderCacheJanitoring
    @ObservationIgnored private var renderTask: Task<Void, Never>?
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
        renderer: any AIChainRendering,
        janitor: any RenderCacheJanitoring,
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
        self.renderer = renderer
        self.janitor = janitor
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
        engine.pause()
        await lastSave?.value
        await autosaver.flush()
        // Only the current state's renders are needed once the history is gone (SPEC § 6.4).
        if isLoaded, !isReadOnly {
            try? await janitor.prune(projectID: project.id, sourceRange: project.clips[0].sourceRange, current: project.editState)
        }
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
        commit()
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
        guard !chain.operations.isEmpty else {
            renderTask = nil
            renderProgress = nil
            rendered = RenderedChain(prefixes: [], output: workingAudio)
            renderedPeaks = nil
            playCurrentSource()
            sweepRenders()
            return
        }
        let source = workingAudio
        let relay = RenderProgressRelay(model: self, request: request)
        renderTask = Task { [weak self, renderer] in
            do {
                let result = try await renderer.render(source: source, chain: chain, progress: relay.report)
                self?.renderFinished(result, request: request)
            } catch is CancellationError {
            } catch {
                guard let self, self.renderRequest == request else { return }
                self.renderTask = nil
                self.renderProgress = nil
                self.failure = .cantRender
            }
        }
    }

    fileprivate func renderProgressed(_ progress: Double, request: Int) {
        guard request == renderRequest, renderTask != nil, progress < 1 else { return }
        renderProgress = progress
    }

    private func renderFinished(_ result: RenderedChain, request: Int) {
        guard request == renderRequest else { return }
        renderTask = nil
        renderProgress = nil
        rendered = result
        if let step = auditionedStep, !result.prefixes.indices.contains(step) { auditionedStep = nil }
        playCurrentSource()
        sweepRenders()
        loadRenderedPeaks(of: result.output)
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

    nonisolated func report(_ progress: Double) {
        Task { @MainActor in self.model?.renderProgressed(progress, request: self.request) }
    }
}
