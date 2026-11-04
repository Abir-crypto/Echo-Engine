import EchoCore
import EchoCoreFakes
import Foundation
@testable import EchoEngine
import Testing

@MainActor
struct RecordModelTests {
    private let builtIn = AudioInput(id: "built-in", name: "iPhone Microphone", kind: .builtInMic, channelCount: 1, supportsStereo: true)
    private let usb = AudioInput(id: "usb", name: "USB interface", kind: .usb, channelCount: 2, supportsStereo: false)
    private let started = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Fixture {
        let model: RecordModel
        let engine: FakeRecordingEngine
        let devices: FakeAudioDeviceManager
        let projects: FakeProjectRepository
        let builder: FakeRecordedProjectBuilder
        let idleTimer: FakeIdleTimer
        let activity: FakeRecordingActivity
        let relay: RecordingStopRelay
        let settings: FakeAppSettingsStore
        let backingTracks: FakeBackingTrackStore
    }

    private func fixture(
        inputs: [AudioInput]? = nil, builder: FakeRecordedProjectBuilder = FakeRecordedProjectBuilder(),
        recording: RecordingSettings = RecordingSettings(), songKey: MusicalKey? = nil
    ) -> Fixture {
        let settings = FakeAppSettingsStore(tint: .teal)
        settings.recording = recording
        let backingTracks = FakeBackingTrackStore()
        let devices = FakeAudioDeviceManager(inputs: inputs ?? [builtIn, usb])
        let engine = FakeRecordingEngine(inputChannels: 2, peaks: [0.5, 0.05])
        let projects = FakeProjectRepository()
        let idleTimer = FakeIdleTimer()
        let activity = FakeRecordingActivity()
        let relay = RecordingStopRelay()
        let model = RecordModel(
            engine: engine, devices: devices, interruptions: RecordingInterruptions(devices: devices, engine: engine),
            projects: projects, builder: builder, backingTracks: backingTracks, keyDetector: FakeKeyDetector(key: songKey),
            idleTimer: idleTimer, activity: activity, stopRelay: relay,
            settings: settings, clock: FakeClock(now: started),
            title: { "Recording at \($0.timeIntervalSince1970)" }
        )
        return Fixture(
            model: model, engine: engine, devices: devices, projects: projects, builder: builder, idleTimer: idleTimer,
            activity: activity, relay: relay, settings: settings, backingTracks: backingTracks
        )
    }

    /// Prepared on the interface with both channels chosen and named.
    private func recordingOnInterface() async -> Fixture {
        let fixture = fixture()
        await fixture.model.appear()
        fixture.model.selectInput(id: usb.id)
        fixture.model.setChannel(1, isOn: true)
        fixture.model.renameChannel(0, to: " Host ")
        fixture.model.renameChannel(1, to: "Guest 1")
        await fixture.model.record()
        return fixture
    }

    // MARK: Input

    @Test func appearingPreparesTheBuiltInMic() async {
        let fixture = fixture()
        await fixture.model.appear()
        #expect(fixture.devices.microphoneRequests == 1)
        #expect(fixture.devices.recordingActivations == 1)
        #expect(fixture.model.selectedInputID == builtIn.id)
        #expect(fixture.devices.selectedInput == builtIn)
        #expect(fixture.model.channels == [RecordModel.Channel(index: 0, name: "iPhone Microphone", isOn: true)])
        #expect(fixture.engine.state == .ready)
        #expect(fixture.engine.configuration == .mono(channels: [0]))
        #expect(fixture.model.canRecord)
        #expect(fixture.model.offersStereo)
        #expect(!fixture.model.offersChannelChoice)
    }

    @Test func theInputInUseComesFirst() async {
        let fixture = fixture()
        fixture.devices.currentInputID = usb.id
        await fixture.model.appear()
        #expect(fixture.model.selectedInputID == usb.id)
    }

    @Test func withoutTheMicrophoneNothingStarts() async {
        let fixture = fixture()
        fixture.devices.microphoneAccess = false
        await fixture.model.appear()
        #expect(fixture.model.problem == .microphoneDenied)
        #expect(fixture.engine.state == .idle)
        #expect(!fixture.model.canChangeInput)
        #expect(!fixture.model.canRecord)
    }

    @Test func anInterfaceOffersItsChannelsFirstOneChosen() async {
        let fixture = fixture()
        await fixture.model.appear()
        fixture.model.selectInput(id: usb.id)
        #expect(fixture.model.offersChannelChoice)
        #expect(fixture.model.channels.map(\.isOn) == [true, false])
        #expect(fixture.model.channels.map(\.name) == ["Channel 1", "Channel 2"])
        fixture.model.setChannel(1, isOn: true)
        #expect(fixture.engine.configuration == .mono(channels: [0, 1]))
        fixture.model.setChannel(0, isOn: false)
        fixture.model.setChannel(1, isOn: false)
        #expect(!fixture.model.canRecord, "nothing to record")
        #expect(fixture.engine.configuration == .mono(channels: [0]), "still metering")
    }

    @Test func theBuiltInMicCanRecordStereo() async {
        let fixture = fixture()
        await fixture.model.appear()
        fixture.model.setBuiltInMode(.stereo)
        #expect(fixture.devices.builtInMode == .stereo)
        #expect(fixture.model.channels.map(\.name) == ["Left", "Right"])
        #expect(fixture.engine.configuration == .builtInStereo)
    }

    @Test func aStereoMicThatDeliversMonoFallsBackToMono() async {
        let fixture = fixture()
        fixture.engine.inputChannels = 1
        await fixture.model.appear()
        fixture.model.setBuiltInMode(.stereo)
        #expect(fixture.model.builtInMode == .mono)
        #expect(fixture.engine.configuration == .mono(channels: [0]))
    }

    @Test func aRemovedInputIsReplacedWhileNotRecording() async {
        let fixture = fixture()
        fixture.devices.currentInputID = usb.id
        await fixture.model.appear()
        fixture.devices.inputs = [builtIn]
        fixture.devices.currentInputID = builtIn.id
        fixture.model.handle(.availableInputsChanged)
        #expect(fixture.model.selectedInputID == builtIn.id)
        #expect(fixture.devices.selectedInput == builtIn)
    }

    // MARK: Take

    @Test func recordingWritesTheMarkerAndShowsTheStatus() async throws {
        let fixture = await recordingOnInterface()
        #expect(fixture.engine.state == .recording)
        #expect(fixture.model.hasTake)
        #expect(!fixture.model.canChangeInput, "locked while recording")
        let folder = try #require(fixture.engine.takeFolder)
        #expect(try TakeSession.read(from: folder) == TakeSession(
            startedAt: started, channelNames: ["Host", "Guest 1"],
            parameterChanges: [.init(time: 0, parameter: .inputGain, value: 0), .init(time: 0, parameter: .suppression, value: 0)]
                + RecordModel.autoTuneChanges(from: nil, to: AutoTuneSettings(), at: 0)
        ))
        #expect(fixture.idleTimer.keepsScreenOn)
        #expect(fixture.activity.isShown)
        #expect(fixture.activity.tint == .teal)
        #expect(fixture.relay.handler != nil)
    }

    @Test func notEnoughSpaceSaysHowMuchAndLeavesNothing() async {
        let fixture = fixture()
        fixture.engine.startError = .notEnoughSpace(availableBytes: 320_000_000)
        await fixture.model.appear()
        await fixture.model.record()
        #expect(fixture.model.problem == .notEnoughSpace(availableBytes: 320_000_000))
        #expect(!fixture.model.hasTake)
        let id = await fixture.projects.createdFolderIDs.first
        #expect(id.map { !FileManager.default.fileExists(atPath: fixture.projects.folder(for: $0).url.path()) } == true)
        #expect(!fixture.activity.isShown)
    }

    @Test func stopMakesTheProjectAndOpensIt() async throws {
        let fixture = await recordingOnInterface()
        let id = try #require(await fixture.projects.createdFolderIDs.first)
        await fixture.model.stop()

        let call = try #require(await fixture.builder.calls.first)
        #expect(call.id == id)
        #expect(call.title == "Recording at 1800000000.0")
        #expect(call.editingSource == .processed)
        #expect(call.session.channelNames == ["Host", "Guest 1"])
        #expect(fixture.model.finishedProjectID == id)
        #expect(!fixture.model.hasTake)
        #expect(fixture.engine.finishedTakes == 1)
        #expect(!fixture.idleTimer.keepsScreenOn)
        #expect(!fixture.activity.isShown)
        #expect(fixture.relay.handler == nil)
        fixture.model.didOpenFinishedProject()
        #expect(fixture.model.finishedProjectID == nil)
    }

    @Test func theLiveActivitysStopEndsTheTake() async throws {
        let fixture = await recordingOnInterface()
        await fixture.relay.stop()
        #expect(fixture.engine.finishedTakes == 1)
        #expect(fixture.model.finishedProjectID != nil)
    }

    @Test func pauseLetsTheScreenLockAndResumeContinues() async {
        let fixture = await recordingOnInterface()
        fixture.model.pause()
        #expect(fixture.engine.state == .paused)
        #expect(!fixture.idleTimer.keepsScreenOn)
        #expect(fixture.model.canResume)
        fixture.model.resume()
        #expect(fixture.engine.state == .recording)
        #expect(fixture.idleTimer.keepsScreenOn)
    }

    @Test func resumingWithoutTheInputSaysWhatToConnect() async {
        let fixture = await recordingOnInterface()
        fixture.devices.inputs = [builtIn]
        fixture.engine.interrupt(.routeChange)
        fixture.model.resume()
        #expect(fixture.model.problem == .inputMissing(name: "USB interface"))
        #expect(fixture.engine.state == .pausedByInterruption(.routeChange))
    }

    @Test func metersFallSlowlyAndTheTakeFollowsTheEngine() async throws {
        let fixture = await recordingOnInterface()
        fixture.engine.elapsedSeconds = 4
        fixture.model.tick()
        #expect(fixture.model.levels == [MeterScale.fraction(forPeak: 0.5), MeterScale.fraction(forPeak: 0.05)])
        fixture.engine.peaks = [0, 0]
        fixture.model.tick()
        #expect(abs(fixture.model.levels[0] - (MeterScale.fraction(forPeak: 0.5) - RecordModel.meterFall)) < 1e-9)
        #expect(fixture.activity.updates.last?.elapsedSeconds == 4)
        #expect(fixture.activity.updates.last?.isPaused == false)

        fixture.engine.interrupt(.interruption)
        fixture.model.tick()
        let folder = try #require(fixture.engine.takeFolder)
        #expect(try TakeSession.read(from: folder).markers == [RecordingMetadata.Marker(time: 4, kind: .interruption)],
                "a crash from here keeps the marker")
        #expect(fixture.activity.updates.last?.isPaused == true)
    }

    @Test func aTakeTheEngineEndedIsSavedAndExplained() async throws {
        let fixture = await recordingOnInterface()
        fixture.engine.end(.lowStorage)
        fixture.model.tick()
        for _ in 0..<50 where fixture.model.stopNotice == nil {
            await Task.yield()
        }
        #expect(fixture.model.stopNotice == .lowStorage)
        #expect(fixture.model.finishedProjectID == nil, "not opened behind the person's back")
        let id = try #require(fixture.model.noticeProjectID)
        fixture.model.openNoticeProject()
        #expect(fixture.model.finishedProjectID == id)
        #expect(fixture.model.stopNotice == nil)
    }

    @Test func aTakeThatCantBecomeAProjectStaysForRecovery() async throws {
        let fixture = fixture(builder: FakeRecordedProjectBuilder(error: .cantCreateProject))
        await fixture.model.appear()
        await fixture.model.record()
        let folder = try #require(fixture.engine.takeFolder)
        await fixture.model.stop()
        #expect(fixture.model.problem == .cantSave)
        #expect(fixture.model.finishedProjectID == nil)
        #expect(!fixture.model.hasTake)
        #expect(FileManager.default.fileExists(atPath: folder.session.path()), "the marker stays: offered at the next launch")
    }

    @Test func leavingTheTabStopsMeteringButNotATake() async {
        let idle = fixture()
        await idle.model.appear()
        idle.model.disappear()
        #expect(idle.engine.state == .idle)

        let recording = await recordingOnInterface()
        recording.model.disappear()
        #expect(recording.engine.state == .recording)
        #expect(!recording.idleTimer.keepsScreenOn, "the screen may lock away from the tab")
        await recording.model.appear()
        #expect(recording.idleTimer.keepsScreenOn)
    }

    // MARK: Live processing (F11.T02)

    @Test func processingChangesDuringATakeAreLogged() async throws {
        let fixture = await recordingOnInterface()
        fixture.engine.elapsedSeconds = 7
        fixture.model.setSuppression(.high)
        fixture.model.setInputGain(3)
        fixture.model.setInputGain(4.5)
        fixture.model.commitInputGain()
        #expect(fixture.engine.suppression.level == .high)
        #expect(fixture.engine.inputGainDB == 4.5)
        let folder = try #require(fixture.engine.takeFolder)
        #expect(try TakeSession.read(from: folder).parameterChanges.suffix(2) == [
            .init(time: 7, parameter: .suppression, value: 2), .init(time: 7, parameter: .inputGain, value: 4.5),
        ], "one entry per released slider")
        await fixture.model.stop()
        let call = try #require(await fixture.builder.calls.first)
        #expect(call.session.parameterChanges.count == 2 + 6 + 2, "start values, then the two changes, into the project")
    }

    @Test func settingsBeforeATakeAreNotLogged() async {
        let fixture = fixture()
        await fixture.model.appear()
        fixture.model.setSuppression(.standard)
        fixture.model.setInputGain(-3)
        fixture.model.commitInputGain()
        #expect(fixture.engine.suppression.level == .standard)
        await fixture.model.record()
        let folder = fixture.engine.takeFolder
        #expect(folder.flatMap { try? Array(TakeSession.read(from: $0).parameterChanges.prefix(2)) } == [
            .init(time: 0, parameter: .inputGain, value: -3), .init(time: 0, parameter: .suppression, value: 1),
        ], "the take starts from them")
    }

    // MARK: Monitoring and remembered settings (F11.T03)

    @Test func monitoringOnlyPlaysThroughHeadphones() async {
        let fixture = fixture()
        await fixture.model.appear()
        #expect(!fixture.model.offersMonitoring, "the speaker: no Monitor row")
        fixture.model.setMonitoring(true)
        #expect(fixture.engine.monitorVolume == 0, "never through the speaker")

        fixture.devices.outputKind = .wiredHeadphones
        fixture.model.handle(.availableInputsChanged)
        #expect(fixture.model.offersMonitoring)
        #expect(fixture.engine.monitorVolume == 0.8)
        fixture.model.setMonitorVolume(0.5)
        #expect(fixture.engine.monitorVolume == 0.5)

        fixture.devices.outputKind = .speaker
        fixture.model.handle(.outputDeviceRemoved)
        #expect(fixture.engine.monitorVolume == 0, "unplugged: silent at once")
        #expect(fixture.settings.recording == RecordingSettings(isMonitoring: true, monitorVolume: 0.5), "remembered")
    }

    @Test func monitoringStartsOff() async {
        let fixture = fixture()
        fixture.devices.outputKind = .wiredHeadphones
        await fixture.model.appear()
        #expect(!fixture.model.isMonitoring)
        #expect(fixture.engine.monitorVolume == 0)
    }

    @Test func settingsCarryOverToTheNextRecording() async {
        let fixture = fixture(recording: RecordingSettings(suppression: .high, inputGainDB: 3))
        await fixture.model.appear()
        #expect(fixture.engine.suppression.level == .high)
        #expect(fixture.engine.inputGainDB == 3)
        fixture.model.setSuppression(.standard)
        fixture.model.setInputGain(-2)
        fixture.model.commitInputGain()
        #expect(fixture.settings.recording.suppression == .standard)
        #expect(fixture.settings.recording.inputGainDB == -2)
    }

    @Test func theRowCaptionSaysWhatRuns() {
        #expect(SuppressionCaption(state: SuppressionState(level: .high, effective: .standard, usesVoiceProcessing: true)) != nil)
        #expect(SuppressionCaption(state: SuppressionState(level: .standard, effective: .standard, usesVoiceProcessing: false)) != nil)
        #expect(SuppressionCaption(state: SuppressionState(level: .standard, effective: .standard, usesVoiceProcessing: true)) == nil)
        #expect(SuppressionCaption(state: .off) == nil)
    }

    // MARK: Auto-tune (F12.T03)

    @Test func autoTuneCarriesOverAndItsChangesAreLogged() async throws {
        let fixture = fixture(recording: RecordingSettings(autoTune: AutoTuneSettings(isOn: true, key: 9, scale: .minor)))
        await fixture.model.appear()
        #expect(fixture.engine.autoTune == AutoTuneSettings(isOn: true, key: 9, scale: .minor), "the last recording's settings")
        await fixture.model.record()
        let folder = try #require(fixture.engine.takeFolder)
        let start = try TakeSession.read(from: folder).parameterChanges
        #expect(start.contains(.init(time: 0, parameter: .autoTuneKey, value: 9)))
        #expect(start.contains(.init(time: 0, parameter: .autoTune, value: 1)))

        fixture.engine.elapsedSeconds = 3
        var robotic = fixture.model.autoTune
        robotic.style = 0.9
        fixture.model.setAutoTune(robotic)
        robotic.style = 1
        fixture.model.setAutoTune(robotic)
        #expect(fixture.engine.autoTune.style == 1, "applies while the slider moves")
        fixture.model.commitAutoTune()
        #expect(try TakeSession.read(from: folder).parameterChanges.last == .init(time: 3, parameter: .autoTuneStyle, value: 1),
                "one entry, for what changed")
        #expect(fixture.settings.recording.autoTune.style == 1)
    }

    @Test func autoTuneMakesMonitoringTimingMatter() async {
        let fixture = fixture()
        fixture.devices.outputKind = .bluetooth
        await fixture.model.appear()
        fixture.model.setMonitoring(true)
        #expect(!fixture.model.showsWiredHeadphonesTip)
        fixture.model.setAutoTune(AutoTuneSettings(isOn: true))
        #expect(fixture.model.showsWiredHeadphonesTip)
    }

    @Test func theRowSummarisesKeyAndStyle() {
        #expect(AutoTuneSettings(isOn: true, key: 9, scale: .minor).summary == "A minor, natural")
        #expect(AutoTuneSettings(isOn: true, style: 1).summary == "Chromatic, robotic")
        #expect(AutoTuneSettings(isOn: true, key: 1).summary == "C♯ major, natural")
    }

    // MARK: Backing track (F12.T04)

    private let song = URL(filePath: "/Users/someone/Music/My Song.m4a")

    @Test func choosingATrackKeepsACopyAndTurnsMonitoringOn() async {
        let fixture = fixture()
        fixture.devices.outputKind = .wiredHeadphones
        await fixture.model.appear()
        fixture.model.chooseBackingTrack(song)
        #expect(fixture.backingTracks.stored == [song])
        #expect(fixture.engine.backingTrack?.url == fixture.backingTracks.root.appending(path: "stored-1.m4a"))
        #expect(fixture.model.backingTrackName == "My Song")
        #expect(fixture.model.isMonitoring, "monitoring turns on with a backing track (user decision)")
        #expect(fixture.settings.recording.backingTrack == .init(fileName: "stored-1.m4a", displayName: "My Song"))

        fixture.model.chooseBackingTrack(URL(filePath: "/Users/someone/Music/Other.mp3"))
        #expect(fixture.backingTracks.removed == ["stored-1.m4a"], "the previous copy goes")
        fixture.model.removeBackingTrack()
        #expect(fixture.engine.backingTrack == nil)
        #expect(fixture.settings.recording.backingTrack == nil)
        #expect(fixture.backingTracks.removed == ["stored-1.m4a", "stored-2.mp3"])
    }

    @Test func aTakeOverATrackKeepsItAndTheLatencyToMix() async throws {
        let fixture = fixture()
        fixture.devices.outputKind = .wiredHeadphones
        await fixture.model.appear()
        fixture.model.chooseBackingTrack(song)
        fixture.model.setBackingTrackStart(12.5)
        fixture.model.commitBackingTrackStart()
        fixture.model.setBackingTrackVolume(0.6)
        await fixture.model.record()
        let folder = try #require(fixture.engine.takeFolder)
        #expect(fixture.backingTracks.copiedInto == [folder])
        #expect(try TakeSession.read(from: folder).backingTrack == RecordingMetadata.BackingTrack(
            fileName: "backing.m4a", displayName: "My Song", startSeconds: 12.5,
            latencySeconds: fixture.devices.latency.roundTripSeconds, volume: 0.6
        ))
        await fixture.model.stop()
        await fixture.model.saveRecording(withBackingTrack: true)
        let call = try #require(await fixture.builder.calls.first)
        #expect(call.session.backingTrack?.startSeconds == 12.5, "into the project's metadata")
    }

    @Test func theSpeakerNeverPlaysTheTrackIntoATake() async {
        let fixture = fixture()
        await fixture.model.appear()
        fixture.model.chooseBackingTrack(song)
        #expect(fixture.engine.backingTrackVolume == 0.8, "listening before a take works on the speaker")
        await fixture.model.record()
        #expect(fixture.engine.backingTrackVolume == 0, "the microphone would pick it up")
        fixture.devices.outputKind = .wiredHeadphones
        fixture.model.handle(.availableInputsChanged)
        #expect(fixture.engine.backingTrackVolume == 0.8)
    }

    @Test func theLastTrackComesBackNextTime() async {
        let fixture = fixture(recording: RecordingSettings(
            backingTrack: .init(fileName: "kept.m4a", displayName: "Kept", startSeconds: 4, volume: 0.5)
        ))
        await fixture.model.appear()
        #expect(fixture.engine.backingTrack?.url == fixture.backingTracks.root.appending(path: "kept.m4a"))
        #expect(fixture.engine.backingTrackStart == 4)
        #expect(fixture.model.backingTrackName == "Kept")
    }

    @Test func anUnplayableFileSaysSo() async {
        let fixture = fixture()
        fixture.engine.backingTrackError = .cantReadBackingTrack
        await fixture.model.appear()
        fixture.model.chooseBackingTrack(song)
        #expect(fixture.model.problem == .cantReadBackingTrack)
        #expect(fixture.backingTracks.removed == ["stored-1.m4a"], "its copy is removed again")
        #expect(fixture.settings.recording.backingTrack == nil)
    }

    // MARK: Song key (F12.T05)

    @Test func theBackingTracksKeyIsOfferedToAutoTune() async {
        let fixture = fixture(songKey: MusicalKey(tonic: 9, scale: .minor))
        fixture.devices.outputKind = .wiredHeadphones
        await fixture.model.appear()
        fixture.model.chooseBackingTrack(song)
        await fixture.model.keyDetection?.value
        #expect(fixture.model.songKey == MusicalKey(tonic: 9, scale: .minor))
        #expect(fixture.model.suggestedSongKey == nil, "not while auto-tune is off")
        fixture.model.setAutoTune(AutoTuneSettings(isOn: true))
        #expect(fixture.model.suggestedSongKey == MusicalKey(tonic: 9, scale: .minor))
        fixture.model.useSongKey()
        #expect(fixture.engine.autoTune.key == 9)
        #expect(fixture.engine.autoTune.scale == .minor)
        #expect(fixture.settings.recording.autoTune.key == 9, "remembered")
        #expect(fixture.model.suggestedSongKey == nil, "already in that key")
        fixture.model.removeBackingTrack()
        #expect(fixture.model.songKey == nil)
    }

    // MARK: Finish with a backing track (F12.T06)

    @Test func overABackingTrackStopAsksHowToSave() async throws {
        let fixture = fixture()
        fixture.devices.outputKind = .wiredHeadphones
        await fixture.model.appear()
        fixture.model.chooseBackingTrack(song)
        await fixture.model.record()
        let id = try #require(await fixture.projects.createdFolderIDs.first)
        await fixture.model.stop()
        #expect(fixture.model.pendingSave?.id == id, "asks first")
        #expect(await fixture.builder.calls.isEmpty)
        #expect(!fixture.model.canRecord, "one thing at a time")
        #expect(fixture.engine.finishedTakes == 1, "the take itself is finished at once")

        await fixture.model.saveRecording(withBackingTrack: true)
        #expect(await fixture.builder.calls.first?.editingSource == .mix)
        #expect(fixture.model.finishedProjectID == id)
        #expect(fixture.model.pendingSave == nil)
    }

    @Test func vocalOnlyKeepsTheProcessedTake() async throws {
        let fixture = fixture()
        await fixture.model.appear()
        fixture.model.chooseBackingTrack(song)
        await fixture.model.record()
        await fixture.model.stop()
        await fixture.model.saveRecording(withBackingTrack: false)
        #expect(await fixture.builder.calls.first?.editingSource == .processed)
    }

    @Test func withoutABackingTrackNothingIsAsked() async {
        let fixture = fixture()
        await fixture.model.appear()
        await fixture.model.record()
        await fixture.model.stop()
        #expect(fixture.model.pendingSave == nil)
        #expect(await fixture.builder.calls.first?.editingSource == .processed)
    }
}
