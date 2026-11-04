import EchoCore
import EchoCoreFakes
@testable import EchoEngine
import Foundation
import Testing

/// Switching a recording between its processed and unprocessed take (SPEC § 13.3, user decision).
@MainActor
struct EditorRecordingTakeTests {
    private let renders = FakeRenderCache()
    private let waveforms = FakeWaveformProvider(peaks: WaveformPeaks(sampleRate: 48_000, sourceFrameCount: 512, peaks: [0.2, 0.5]))
    private let renderer = FakeAIChainRenderer()
    private let recordings = FakeRecordedProjectBuilder()
    private let autosaver = FakeProjectAutosaver()

    private func model(_ editingSource: RecordingMetadata.Take) -> (EditorModel, FakePlaybackEngine) {
        var project = PreviewProjects.all()[1]
        project.origin = .recorded
        project.recording = RecordingMetadata(channelNames: ["Voice"], editingSource: editingSource)
        project.clips[0].aiStack = [AIOperation(kind: .noiseSuppression, strength: 0.8)]
        let engine = FakePlaybackEngine(duration: project.sourceInfo.duration)
        let model = EditorModel(
            stored: StoredProject(project: project, isReadOnly: false), engine: engine, repository: FakeProjectRepository(),
            waveforms: waveforms, devices: FakeAudioDeviceManager(),
            storage: FakeStorageEstimator(editBytes: 1_000, available: 1_000_000), entitlements: FakeEntitlements(),
            capabilities: FakeCapabilities(), renderer: renderer, janitor: FakeRenderCacheJanitor(),
            autoLevel: FakeAutoLevelAnalyzer(), presets: FakePresetRepository(), clock: FakeClock(),
            renders: renders, recordings: recordings, makeAutosaver: { [autosaver] _ in autosaver }
        )
        return (model, engine)
    }

    @Test func aRecordingCanEditItsUnprocessedTakeAndBack() async {
        let (model, engine) = model(.processed)
        await model.open()
        #expect(model.canSwitchRecordingTake)
        #expect(!model.editsUnprocessedRecording)
        let rendersBefore = await renderer.chains.count

        await model.setEditsUnprocessedRecording(true)
        #expect(model.editsUnprocessedRecording)
        #expect(model.project.sourceFileName == "takes/raw.caf")
        #expect(await recordings.switches == [.raw])
        #expect(await renders.removedAllProjectIDs == [model.project.id], "renders of the other take go")
        #expect(await waveforms.removedProjectIDs == [model.project.id])
        #expect(engine.loadedAudio != nil, "playback reloads")
        #expect(await renderer.chains.count > rendersBefore, "the AI stack renders again")
        await model.close()
        #expect(await autosaver.scheduled.last?.recording?.editingSource == .raw, "saved")

        await model.setEditsUnprocessedRecording(false)
        #expect(await recordings.switches == [.raw, .processed])
    }

    @Test func aMixKeepsItsMix() async {
        let (model, _) = model(.mix)
        await model.open()
        #expect(!model.canSwitchRecordingTake)
    }

    @Test func importedProjectsHaveNoTakeToSwitch() async {
        var project = PreviewProjects.all()[1]
        project.recording = nil
        let model = EditorModel(
            stored: StoredProject(project: project, isReadOnly: false), engine: FakePlaybackEngine(duration: 10),
            repository: FakeProjectRepository(), waveforms: waveforms, devices: FakeAudioDeviceManager(),
            storage: FakeStorageEstimator(editBytes: 1_000, available: 1_000_000), entitlements: FakeEntitlements(),
            capabilities: FakeCapabilities(), renderer: renderer, janitor: FakeRenderCacheJanitor(),
            autoLevel: FakeAutoLevelAnalyzer(), presets: FakePresetRepository(), clock: FakeClock(),
            renders: renders, recordings: recordings, makeAutosaver: { [autosaver] _ in autosaver }
        )
        await model.open()
        #expect(!model.canSwitchRecordingTake)
    }
}
