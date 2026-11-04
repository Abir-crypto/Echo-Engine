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
    }

    private func fixture(
        inputs: [AudioInput]? = nil, builder: FakeRecordedProjectBuilder = FakeRecordedProjectBuilder()
    ) -> Fixture {
        let devices = FakeAudioDeviceManager(inputs: inputs ?? [builtIn, usb])
        let engine = FakeRecordingEngine(inputChannels: 2, peaks: [0.5, 0.05])
        let projects = FakeProjectRepository()
        let idleTimer = FakeIdleTimer()
        let activity = FakeRecordingActivity()
        let relay = RecordingStopRelay()
        let model = RecordModel(
            engine: engine, devices: devices, interruptions: RecordingInterruptions(devices: devices, engine: engine),
            projects: projects, builder: builder, idleTimer: idleTimer, activity: activity, stopRelay: relay,
            settings: FakeAppSettingsStore(tint: .teal), clock: FakeClock(now: started),
            title: { "Recording at \($0.timeIntervalSince1970)" }
        )
        return Fixture(
            model: model, engine: engine, devices: devices, projects: projects, builder: builder, idleTimer: idleTimer,
            activity: activity, relay: relay
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
        #expect(call.session.parameterChanges.count == 4, "the log goes into the project")
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
        #expect(folder.flatMap { try? TakeSession.read(from: $0).parameterChanges } == [
            .init(time: 0, parameter: .inputGain, value: -3), .init(time: 0, parameter: .suppression, value: 1),
        ], "the take starts from them")
    }
}
