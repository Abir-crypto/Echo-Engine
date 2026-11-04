import EchoCore
import Foundation
import Observation

/// The Record tab (SPEC § 13, mockup `Design/screens/Record.dc.html`): chooses the input and its channels, meters them,
/// records a take and makes it a project on Stop. While a take is open it keeps the session marker (crash recovery),
/// the idle timer, the Live Activity and its Stop in step with the engine, and finishes takes the engine ended by itself
/// (low storage, write failure). Interruptions go through `RecordingInterruptions`.
@MainActor
@Observable
final class RecordModel {
    enum Problem: Equatable {
        /// The person didn't allow the microphone.
        case microphoneDenied
        case noInput
        /// Below the storage policy's start minimum (SPEC § 15).
        case notEnoughSpace(availableBytes: Int64)
        case cantStart
        /// The take's input is gone; it continues once it's back (SPEC § 13.7).
        case inputMissing(name: String)
        /// A call or another app still holds the microphone.
        case microphoneBusy
        /// The take couldn't become a project; it stays on disk and is offered again at the next launch.
        case cantSave
        /// The chosen backing track can't be played.
        case cantReadBackingTrack
    }

    /// One channel of the input as the take records it.
    struct Channel: Identifiable, Equatable {
        /// The input channel (0-based).
        let index: Int
        var name: String
        var isOn: Bool
        var id: Int { index }
    }

    private(set) var inputs: [AudioInput] = []
    private(set) var selectedInputID: String?
    private(set) var builtInMode: BuiltInMicMode = .mono
    private(set) var channels: [Channel] = []
    /// Meter position (0…1) of every input channel, falling back slowly after a peak.
    private(set) var levels: [Double] = []
    private(set) var problem: Problem?
    /// Why the engine ended a take by itself; the take was saved as `noticeProjectID`.
    private(set) var stopNotice: TakeEndReason?
    private(set) var noticeProjectID: UUID?
    /// A finished recording to open in the Editor.
    private(set) var finishedProjectID: UUID?
    private(set) var isStarting = false
    private(set) var isFinishing = false
    var isDimmed = false
    /// Where the session plays: monitoring needs headphones (SPEC § 13.4).
    private(set) var outputKind = AudioOutputKind.speaker

    @ObservationIgnored let engine: any RecordingEngine
    @ObservationIgnored private let devices: any AudioDeviceManaging
    @ObservationIgnored private let interruptions: RecordingInterruptions
    @ObservationIgnored private let projects: any ProjectRepository
    @ObservationIgnored private let builder: any RecordedProjectBuilding
    @ObservationIgnored private let backingTracks: any BackingTrackStoring
    @ObservationIgnored private let keyDetector: any KeyDetecting
    /// The backing track's key detection in progress (tests wait for it).
    @ObservationIgnored private(set) var keyDetection: Task<Void, Never>?
    @ObservationIgnored private let idleTimer: any IdleTimerControlling
    @ObservationIgnored private let activity: any RecordingActivityPresenting
    @ObservationIgnored private let stopRelay: RecordingStopRelay
    @ObservationIgnored private let settings: any AppSettingsStore
    @ObservationIgnored private let clock: any DateProviding
    @ObservationIgnored private let title: (Date) -> String
    @ObservationIgnored private var take: OpenTake?
    @ObservationIgnored private var isOnScreen = false
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var listeningTasks: [Task<Void, Never>] = []

    private struct OpenTake {
        let id: UUID
        let folder: TakeFolder
        var session: TakeSession
    }

    /// How far a meter falls per update (30 a second): 20 dB a second over the meter's 60 dB.
    static let meterFall = 20.0 / 30 / -MeterScale.floorDB

    /// `title` makes the default title from the time a take started (SPEC § 5.4).
    init(
        engine: any RecordingEngine,
        devices: any AudioDeviceManaging,
        interruptions: RecordingInterruptions,
        projects: any ProjectRepository,
        builder: any RecordedProjectBuilding,
        backingTracks: any BackingTrackStoring,
        keyDetector: any KeyDetecting,
        idleTimer: any IdleTimerControlling,
        activity: any RecordingActivityPresenting,
        stopRelay: RecordingStopRelay,
        settings: any AppSettingsStore,
        clock: any DateProviding,
        title: @escaping (Date) -> String
    ) {
        self.engine = engine
        self.devices = devices
        self.interruptions = interruptions
        self.projects = projects
        self.builder = builder
        self.backingTracks = backingTracks
        self.keyDetector = keyDetector
        self.idleTimer = idleTimer
        self.activity = activity
        self.stopRelay = stopRelay
        self.settings = settings
        self.clock = clock
        self.title = title
    }

    // MARK: State

    var state: RecordingState { engine.state }
    var selectedInput: AudioInput? { inputs.first { $0.id == selectedInputID } }
    /// The channels the take records, in take order.
    var recordedChannels: [Channel] { channels.filter(\.isOn) }
    /// A take is open: the input and channels are locked (SPEC § 13.2).
    var hasTake: Bool { take != nil }
    var canChangeInput: Bool { take == nil && !isStarting && problem != .microphoneDenied }
    var canRecord: Bool { take == nil && pendingSave == nil && !isStarting && state == .ready && !recordedChannels.isEmpty }
    var canResume: Bool {
        switch state {
        case .paused: true
        case .pausedByInterruption: interruptions.canResume
        default: false
        }
    }
    /// Whether the selected built-in mic can record stereo.
    var offersStereo: Bool { selectedInput?.kind == .builtInMic && selectedInput?.supportsStereo == true }
    /// Channels to choose from: only interfaces with several.
    var offersChannelChoice: Bool { selectedInput?.kind != .builtInMic && channels.count > 1 }

    func level(of channel: Channel) -> Double {
        levels.indices.contains(channel.index) ? levels[channel.index] : 0
    }

    // MARK: Screen

    /// The tab appeared: asks for the microphone, sets up the session and the input, starts the meters.
    func appear() async {
        isOnScreen = true
        defer { updateIdleTimer() }
        guard take == nil else { return }
        guard await devices.requestMicrophoneAccess() else {
            problem = .microphoneDenied
            return
        }
        if problem == .microphoneDenied { problem = nil }
        do {
            try devices.activateForRecording()
        } catch {
            problem = .cantStart
            return
        }
        startListening()
        // The settings of the last recording carry over (SPEC § 13.4).
        engine.setSuppression(settings.recording.suppression)
        engine.setInputGain(settings.recording.inputGainDB)
        engine.setAutoTune(settings.recording.autoTune)
        restoreBackingTrack()
        refreshOutput()
        refreshInputs()
        configure()
        startMeters()
    }

    /// The tab went away: the screen may lock again; without a take the engine stops.
    func disappear() {
        isOnScreen = false
        engine.previewBackingTrack(false)
        updateIdleTimer()
        guard take == nil else { return }
        stopMeters()
        engine.shutDown()
    }

    // MARK: Input

    func selectInput(id: String) {
        guard canChangeInput, id != selectedInputID else { return }
        selectedInputID = id
        channels = []
        configure()
    }

    func setBuiltInMode(_ mode: BuiltInMicMode) {
        guard canChangeInput, mode != builtInMode else { return }
        builtInMode = mode
        channels = []
        configure()
    }

    func setChannel(_ index: Int, isOn: Bool) {
        guard canChangeInput, let position = channels.firstIndex(where: { $0.index == index }) else { return }
        channels[position].isOn = isOn
        prepareEngine()
    }

    func renameChannel(_ index: Int, to name: String) {
        guard canChangeInput, let position = channels.firstIndex(where: { $0.index == index }) else { return }
        channels[position].name = name
    }

    // MARK: Take

    func record() async {
        guard canRecord else { return }
        isStarting = true
        defer { isStarting = false }
        problem = nil
        let id = UUID()
        // The processing settings from the start, for re-processing later (SPEC § 13.3).
        var session = TakeSession(
            startedAt: clock.now, channelNames: recordedChannels.map(channelName),
            parameterChanges: [
                .init(time: 0, parameter: .inputGain, value: engine.inputGainDB),
                .init(time: 0, parameter: .suppression, value: engine.suppression.level.parameterChangeValue),
            ] + Self.autoTuneChanges(from: nil, to: engine.autoTune, at: 0)
        )
        do {
            let folder = try await projects.createFolder(for: id).takeFolder
            // The backing track goes with the take, for mixing (SPEC § 13.6).
            if let track = engine.backingTrack, let stored = settings.recording.backingTrack {
                session.backingTrack = RecordingMetadata.BackingTrack(
                    fileName: try backingTracks.copy(track.url, into: folder), displayName: stored.displayName,
                    startSeconds: engine.backingTrackStart, latencySeconds: devices.latency.roundTripSeconds, volume: stored.volume
                )
            }
            // The marker exists before any audio does, so a kill from here on leaves a take to recover.
            try session.write(to: folder)
            if let selectedInputID { interruptions.track(inputID: selectedInputID, builtInMode: builtInMode) }
            try engine.startTake(in: folder)
            take = OpenTake(id: id, folder: folder, session: session)
        } catch {
            try? await projects.delete(id: id)
            if case RecordingError.notEnoughSpace(let available) = error {
                problem = .notEnoughSpace(availableBytes: available)
            } else {
                problem = .cantStart
            }
            return
        }
        activity.start(tint: settings.tint)
        stopRelay.handler = { [weak self] in await self?.stop() }
        updateIdleTimer()
        applyBackingTrackVolume()
    }

    func pause() {
        engine.pause()
        updateIdleTimer()
    }

    func resume() {
        problem = nil
        do {
            if case .pausedByInterruption = state {
                try interruptions.resume()
            } else {
                try engine.resume()
            }
        } catch RecordingError.inputChanged {
            problem = .inputMissing(name: selectedInput?.name ?? "")
        } catch RecordingError.engineUnavailable {
            problem = .microphoneBusy
        } catch {
            problem = .cantStart
        }
        updateIdleTimer()
    }

    /// Ends the take and makes it a project, then opens it (`finishedProjectID`). Also the Live Activity's Stop.
    func stop() async {
        await finish(notice: nil)
    }

    /// A take sung over a backing track, waiting for "Vocal only" or "With backing track" (SPEC § 13.6).
    private(set) var pendingSave: PendingSave?

    struct PendingSave: Equatable {
        let id: UUID
        let session: TakeSession
    }

    /// Saves the pending take as the voice alone, or mixed with its backing track; the vocal take is kept either way.
    func saveRecording(withBackingTrack: Bool) async {
        guard let pending = pendingSave, !isFinishing else { return }
        pendingSave = nil
        isFinishing = true
        defer { isFinishing = false }
        await save(id: pending.id, session: pending.session, editingSource: withBackingTrack ? .mix : .processed, notice: nil)
    }

    private func save(id: UUID, session: TakeSession, editingSource: RecordingMetadata.Take, notice: TakeEndReason?) async {
        do {
            let project = try await builder.buildProject(id: id, title: title(session.startedAt), session: session, editingSource: editingSource)
            if let notice {
                stopNotice = notice
                noticeProjectID = project.id
            } else {
                finishedProjectID = project.id
            }
        } catch RecordingError.emptyTake {
            // Stopped before any audio arrived: nothing to keep.
            try? await projects.delete(id: id)
        } catch {
            // The take and its marker stay: the next launch offers to recover it.
            problem = .cantSave
        }
    }

    func didOpenFinishedProject() {
        finishedProjectID = nil
    }

    /// Opens the take the engine ended by itself.
    func openNoticeProject() {
        finishedProjectID = noticeProjectID
        dismissNotice()
    }

    func dismissNotice() {
        stopNotice = nil
        noticeProjectID = nil
    }

    func dismissProblem() {
        problem = nil
    }

    // MARK: Live processing (SPEC § 13.4)

    var suppression: SuppressionState { engine.suppression }
    var inputGainDB: Double { engine.inputGainDB }

    func setSuppression(_ level: SuppressionLevel) {
        guard level != engine.suppression.level else { return }
        engine.setSuppression(level)
        settings.recording.suppression = level
        log(.suppression, level.parameterChangeValue)
    }

    /// While the slider moves: ramped, not logged.
    func setInputGain(_ db: Double) {
        engine.setInputGain(db)
    }

    /// The slider was released: one entry in the take's log.
    func commitInputGain() {
        settings.recording.inputGainDB = engine.inputGainDB
        log(.inputGain, engine.inputGainDB)
    }

    // MARK: Auto-tune (SPEC § 13.5)

    var autoTune: AutoTuneSettings { engine.autoTune }

    /// Applies at once (sliders too, while they move); `commitAutoTune` logs and remembers.
    func setAutoTune(_ settings: AutoTuneSettings) {
        engine.setAutoTune(settings)
    }

    /// A control was released: remembered for the next recording, and logged in the take.
    func commitAutoTune() {
        let previous = settings.recording.autoTune
        settings.recording.autoTune = engine.autoTune
        for change in Self.autoTuneChanges(from: previous, to: engine.autoTune, at: engine.elapsedSeconds) {
            log(change.parameter, change.value)
        }
    }

    /// The auto-tune settings that differ, as log entries (all of them from `nil`).
    static func autoTuneChanges(
        from old: AutoTuneSettings?, to new: AutoTuneSettings, at time: Double
    ) -> [RecordingMetadata.ParameterChange] {
        let values: [(RecordingMetadata.ParameterChange.Parameter, (AutoTuneSettings) -> Double)] = [
            (.autoTune, { $0.isOn ? 1 : 0 }),
            (.autoTuneKey, { Double($0.key ?? -1) }),
            (.autoTuneScale, { $0.scale == .minor ? 1 : 0 }),
            (.autoTuneStyle, { $0.style }),
            (.autoTuneHumanize, { $0.humanize }),
            (.autoTuneFormants, { $0.preservesFormants ? 1 : 0 }),
        ]
        return values.compactMap { parameter, value in
            guard old.map({ value($0) != value(new) }) ?? true else { return nil }
            return .init(time: time, parameter: parameter, value: value(new))
        }
    }

    // MARK: Backing track (SPEC § 13.6)

    var backingTrack: BackingTrackInfo? { engine.backingTrack }
    /// The chosen file's name, shown only here.
    var backingTrackName: String? { backingTrack == nil ? nil : settings.recording.backingTrack?.displayName }
    var backingTrackStart: Double { engine.backingTrackStart }
    var backingTrackVolume: Double { settings.recording.backingTrack?.volume ?? 0.8 }
    var isPreviewingBackingTrack: Bool { engine.isPreviewingBackingTrack }

    /// Uses a file from Files as the backing track: kept in the app (so it stays if the original moves) and turns
    /// monitoring on (user decision, SPEC § 13.4).
    func chooseBackingTrack(_ url: URL) {
        guard take == nil else { return }
        let previous = settings.recording.backingTrack
        do {
            let copy = try backingTracks.store(url)
            do {
                try engine.loadBackingTrack(copy)
            } catch {
                backingTracks.remove(fileName: copy.lastPathComponent)
                throw error
            }
            if let previous { backingTracks.remove(fileName: previous.fileName) }
            settings.recording.backingTrack = RecordingSettings.StoredBackingTrack(
                fileName: copy.lastPathComponent, displayName: url.deletingPathExtension().lastPathComponent,
                volume: previous?.volume ?? 0.8
            )
            if problem == .cantReadBackingTrack { problem = nil }
            setMonitoring(true)
            applyBackingTrackVolume()
            detectSongKey()
        } catch {
            problem = .cantReadBackingTrack
        }
    }

    func removeBackingTrack() {
        guard take == nil else { return }
        engine.removeBackingTrack()
        if let stored = settings.recording.backingTrack { backingTracks.remove(fileName: stored.fileName) }
        settings.recording.backingTrack = nil
        detectSongKey()
    }

    /// While the slider moves; locked during a take.
    func setBackingTrackStart(_ seconds: Double) {
        engine.setBackingTrackStart(seconds)
    }

    func commitBackingTrackStart() {
        settings.recording.backingTrack?.startSeconds = engine.backingTrackStart
    }

    func setBackingTrackVolume(_ volume: Double) {
        settings.recording.backingTrack?.volume = min(1, max(0, volume))
        applyBackingTrackVolume()
    }

    func previewBackingTrack(_ isPlaying: Bool) {
        engine.previewBackingTrack(isPlaying)
    }

    /// The track chosen last time, if its copy is still there.
    private func restoreBackingTrack() {
        guard engine.backingTrack == nil, let stored = settings.recording.backingTrack else { return }
        do {
            try engine.loadBackingTrack(backingTracks.root.appending(path: stored.fileName))
            engine.setBackingTrackStart(stored.startSeconds)
            detectSongKey()
        } catch {
            settings.recording.backingTrack = nil
        }
    }

    // MARK: Song key (SPEC § 13.5)

    /// The backing track's key, once detected.
    private(set) var songKey: MusicalKey?

    /// "Song key: A minor. Use it?": while auto-tune is on and set to another key.
    var suggestedSongKey: MusicalKey? {
        guard let songKey, autoTune.isOn, autoTune.key != songKey.tonic || autoTune.scale != songKey.scale else { return nil }
        return songKey
    }

    func useSongKey() {
        guard let songKey else { return }
        var settings = autoTune
        settings.key = songKey.tonic
        settings.scale = songKey.scale
        setAutoTune(settings)
        commitAutoTune()
    }

    private func detectSongKey() {
        keyDetection?.cancel()
        songKey = nil
        guard let url = engine.backingTrack?.url else { return }
        keyDetection = Task { [weak self, keyDetector] in
            let key = try? await keyDetector.detectKey(of: url)
            guard !Task.isCancelled else { return }
            self?.songKey = key ?? nil
        }
    }

    /// Heard through headphones; through the speaker only when listening before a take, never into one.
    private func applyBackingTrackVolume() {
        let isSilenced = take != nil && !outputKind.allowsMonitoring
        engine.setBackingTrackVolume(isSilenced ? 0 : backingTrackVolume)
    }

    // MARK: Monitoring (SPEC § 13.4)

    var isMonitoring: Bool { settings.recording.isMonitoring }
    var monitorVolume: Double { settings.recording.monitorVolume }
    /// The Monitor row shows only with headphones: never through the speaker.
    var offersMonitoring: Bool { outputKind.allowsMonitoring }
    /// "Use wired headphones for monitoring": timing-critical monitoring over Bluetooth or AirPlay.
    var showsWiredHeadphonesTip: Bool {
        isMonitoring && needsTightMonitoring && outputKind != .wiredHeadphones && outputKind != .speaker
    }
    /// Auto-tune or a backing track is on: then monitoring delay matters.
    private var needsTightMonitoring: Bool { autoTune.isOn || backingTrack != nil }

    func setMonitoring(_ isOn: Bool) {
        settings.recording.isMonitoring = isOn
        applyMonitor()
    }

    func setMonitorVolume(_ volume: Double) {
        settings.recording.monitorVolume = min(1, max(0, volume))
        applyMonitor()
    }

    private func refreshOutput() {
        outputKind = devices.outputKind
        applyMonitor()
        applyBackingTrackVolume()
    }

    private func applyMonitor() {
        engine.setMonitorVolume(isMonitoring && outputKind.allowsMonitoring ? monitorVolume : 0)
    }

    /// Adds a setting to the open take's log (SPEC § 13.3) and to its marker file.
    private func log(_ parameter: RecordingMetadata.ParameterChange.Parameter, _ value: Double) {
        guard var take else { return }
        take.session.parameterChanges.append(.init(time: engine.elapsedSeconds, parameter: parameter, value: value))
        self.take = take
        try? take.session.write(to: take.folder)
    }

    // MARK: Meters and take upkeep

    /// One meter update (30 a second while the tab shows or a take is open): levels, the take's marker file, the Live
    /// Activity, and takes the engine ended by itself.
    func tick() {
        let peaks = engine.takePeakLevels()
        levels = peaks.enumerated().map { index, peak in
            let previous = levels.indices.contains(index) ? levels[index] : 0
            return max(MeterScale.fraction(forPeak: peak), previous - Self.meterFall)
        }
        updateIdleTimer()
        guard var take, !isFinishing else { return }
        if case .ended(let reason) = state {
            Task { await finish(notice: reason) }
            return
        }
        if engine.markers != take.session.markers {
            take.session.markers = engine.markers
            self.take = take
            try? take.session.write(to: take.folder)
        }
        let loudest = recordedChannels.map(level(of:)).max() ?? 0
        activity.update(elapsedSeconds: engine.elapsedSeconds, isPaused: state != .recording, level: loudest)
    }

    private func finish(notice: TakeEndReason?) async {
        guard let take, !isFinishing else { return }
        isFinishing = true
        defer { isFinishing = false }
        isDimmed = false
        var session = take.session
        do {
            session.markers = try await engine.finishTake().markers
            if session.backingTrack != nil, notice == nil {
                // Sung over a backing track: the person chooses how to save it (SPEC § 13.6).
                pendingSave = PendingSave(id: take.id, session: session)
            } else {
                // A take the engine ended (low space) is saved as the voice alone.
                await save(id: take.id, session: session, editingSource: .processed, notice: notice)
            }
        } catch {
            problem = .cantSave
        }
        self.take = nil
        activity.end()
        stopRelay.handler = nil
        updateIdleTimer()
        applyBackingTrackVolume()
        if !isOnScreen {
            stopMeters()
            engine.shutDown()
        }
    }

    // MARK: Engine set-up

    private func startListening() {
        guard listeningTasks.isEmpty else { return }
        let events = devices.sessionEvents()
        listeningTasks = [
            Task { [interruptions] in await interruptions.run() },
            Task { [weak self] in
                for await event in events {
                    self?.handle(event)
                }
            },
        ]
    }

    func handle(_ event: AudioSessionEvent) {
        switch event {
        case .availableInputsChanged:
            refreshOutput()
            let previous = selectedInputID
            refreshInputs()
            if take == nil, isOnScreen, selectedInputID != previous { configure() }
        case .interruptionEnded:
            // Without a take the interruption stopped the meters; start them again.
            guard take == nil, isOnScreen, state == .idle else { return }
            try? devices.activateForRecording()
            configure()
        case .outputDeviceRemoved:
            // Headphones unplugged: silent at once, before anything reaches the speaker.
            refreshOutput()
        case .interruptionBegan, .inputDeviceRemoved:
            break
        }
    }

    private func refreshInputs() {
        inputs = devices.availableInputs()
        guard selectedInputID.map({ id in !inputs.contains { $0.id == id } }) ?? true else { return }
        // The input in use (a headset just plugged in), else the built-in mic, else any.
        let current = devices.currentInputID.flatMap { id in inputs.first { $0.id == id } }
        selectedInputID = (current ?? inputs.first { $0.kind == .builtInMic } ?? inputs.first)?.id
        channels = []
    }

    /// Routes the session to the selected input, lists its channels and starts metering them.
    private func configure() {
        guard take == nil else { return }
        guard let input = selectedInput else {
            problem = .noInput
            engine.shutDown()
            return
        }
        if problem == .noInput { problem = nil }
        do {
            try devices.selectInput(id: input.id, builtInMode: builtInMode)
        } catch {
            problem = .noInput
            return
        }
        if channels.isEmpty {
            channels = Self.channels(for: input, mode: builtInMode, count: devices.selectedInputChannelCount)
        }
        prepareEngine()
    }

    private func prepareEngine() {
        do {
            try engine.prepare(configuration)
            if problem == .cantStart { problem = nil }
        } catch RecordingError.channelsUnavailable where builtInMode == .stereo {
            // This device doesn't deliver stereo after all.
            builtInMode = .mono
            channels = []
            configure()
        } catch {
            problem = .cantStart
        }
    }

    /// The take's configuration; with no channel chosen, the first one is metered (nothing can be recorded then).
    private var configuration: RecordingConfiguration {
        if selectedInput?.kind == .builtInMic, builtInMode == .stereo, channels.count == 2 { return .builtInStereo }
        let chosen = recordedChannels.map(\.index)
        return .mono(channels: chosen.isEmpty ? [0] : chosen)
    }

    private func channelName(_ channel: Channel) -> String {
        let name = channel.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? Self.defaultName(ofChannel: channel.index) : name
    }

    static func defaultName(ofChannel index: Int) -> String {
        String(localized: "Channel \(index + 1)", comment: "Default name of an input channel, e.g. Channel 2.")
    }

    /// The built-in mic records one mono or a left and right channel; an interface offers each of its channels, the
    /// first one chosen; a headset is one channel.
    static func channels(for input: AudioInput, mode: BuiltInMicMode, count: Int) -> [Channel] {
        if input.kind == .builtInMic {
            guard mode == .stereo, input.supportsStereo else { return [Channel(index: 0, name: input.name, isOn: true)] }
            return [
                Channel(index: 0, name: String(localized: "Left", comment: "Left channel of the built-in mic in stereo."), isOn: true),
                Channel(index: 1, name: String(localized: "Right", comment: "Right channel of the built-in mic in stereo."), isOn: true),
            ]
        }
        guard count > 1 else { return [Channel(index: 0, name: input.name, isOn: true)] }
        return (0..<count).map { Channel(index: $0, name: defaultName(ofChannel: $0), isOn: $0 == 0) }
    }

    private func startMeters() {
        guard meterTask == nil else { return }
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopMeters() {
        meterTask?.cancel()
        meterTask = nil
        levels = []
    }

    /// The screen stays on only while recording on this tab (SPEC § 13.7).
    private func updateIdleTimer() {
        let keepsOn = isOnScreen && state == .recording
        if idleTimer.keepsScreenOn != keepsOn { idleTimer.keepsScreenOn = keepsOn }
    }
}
