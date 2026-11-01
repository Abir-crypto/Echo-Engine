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
    }

    private(set) var project: Project
    let isReadOnly: Bool
    private(set) var readiness: ProjectReadiness = .ready
    private(set) var isLoaded = false
    /// Waveform of `working.caf`; `nil` until loaded.
    private(set) var peaks: WaveformPeaks?
    /// The loudest peak, so waveforms can be drawn relative to it.
    private(set) var peakLevel: Float = 1
    /// While held, playback compares with the original (wired to the chain in F05/F06).
    private(set) var isHoldingOriginal = false
    /// Undo/redo of `EditState` snapshots (SPEC § 6.5).
    private(set) var history = EditHistory()
    var failure: Failure?

    let engine: any PlaybackEngine
    @ObservationIgnored let autosaver: any ProjectAutosaving
    @ObservationIgnored private let repository: any ProjectRepository
    @ObservationIgnored private let waveforms: any WaveformProviding
    @ObservationIgnored private let devices: any AudioDeviceManaging
    @ObservationIgnored private let storage: any StorageEstimating
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
        let failed = SaveFailureRelay()
        autosaver = makeAutosaver { _ in failed.report() }
        failed.onFailure = { [weak self] in self?.failure = .cantSave }
    }

    var isVideo: Bool { project.mediaType == .video }
    var canEdit: Bool { isLoaded && !isReadOnly }
    var canUndo: Bool { canEdit && history.canUndo }
    var canRedo: Bool { canEdit && history.canRedo }
    var sourceDuration: Double { project.sourceInfo.duration }

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
            isLoaded = true
            followSessionEvents()
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
        engine.pause()
        await lastSave?.value
        await autosaver.flush()
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

    func holdOriginal(_ isHolding: Bool) {
        isHoldingOriginal = isHolding && canEdit
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
    }

    private func restore(_ state: EditState) {
        project.editState = state
        committedState = state
        engine.playbackRange = state.trimRange
        engine.apply(state.manual)
        save()
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
