import EchoCore
import EchoCoreFakes
@testable import EchoEngine
import Foundation
import Testing

private struct LoadFailure: Error {}

@MainActor
struct EditorModelTests {
    private let video = PreviewProjects.all()[0]   // 198 s video
    private let audio = PreviewProjects.all()[1]   // audio
    private let devices = FakeAudioDeviceManager()
    private let autosaver = FakeProjectAutosaver()
    private let repository = FakeProjectRepository()

    private func makeModel(
        _ project: Project,
        readOnly: Bool = false,
        engine: FakePlaybackEngine? = nil,
        storage: FakeStorageEstimator = FakeStorageEstimator(editBytes: 1_000, available: 1_000_000)
    ) -> (EditorModel, FakePlaybackEngine) {
        let engine = engine ?? FakePlaybackEngine(duration: project.sourceInfo.duration)
        let model = EditorModel(
            stored: StoredProject(project: project, isReadOnly: readOnly),
            engine: engine,
            repository: repository,
            waveforms: FakeWaveformProvider(peaks: WaveformPeaks(sampleRate: 48_000, sourceFrameCount: 512, peaks: [0.2, 0.5])),
            devices: devices,
            storage: storage,
            makeAutosaver: { [autosaver] _ in autosaver }
        )
        return (model, engine)
    }

    @Test func openingAVideoLoadsWorkingAudioAndTheSourceVideo() async {
        let (model, engine) = makeModel(video)
        await model.open()

        let folder = repository.folder(for: video.id)
        #expect(model.isLoaded)
        #expect(engine.loadedAudio == folder.working)
        #expect(engine.loadedVideo == folder.source(fileName: "source.mov"))
        #expect(engine.playbackRange == video.trimRange)
        #expect(model.peaks?.peaks == [0.2, 0.5])
        #expect(model.peakLevel == 0.5)
    }

    @Test func openingAudioLoadsNoVideo() async {
        let (model, engine) = makeModel(audio)
        await model.open()
        #expect(engine.loadedAudio != nil)
        #expect(engine.loadedVideo == nil)
    }

    @Test func notEnoughSpaceBlocksTheEditor() async {
        let (model, engine) = makeModel(video, storage: FakeStorageEstimator(editBytes: 3_000, available: 1_000))
        await model.open()
        #expect(model.readiness == .needsSpaceToEdit(2_000))
        #expect(!model.isLoaded)
        #expect(engine.loadedAudio == nil)
    }

    @Test func unplayableAudioIsReported() async {
        let engine = FakePlaybackEngine(duration: 10)
        engine.loadError = LoadFailure()
        let (model, _) = makeModel(audio, engine: engine)
        await model.open()
        #expect(model.failure == .cantPlay)
        #expect(!model.canEdit)
    }

    @Test func playActivatesTheSessionFirst() async {
        let (model, engine) = makeModel(audio)
        await model.open()

        model.togglePlayback()
        #expect(engine.isPlaying)
        #expect(devices.playbackActivations == 1)

        model.togglePlayback()
        #expect(!engine.isPlaying)
    }

    @Test func trimKeepsOneSecondBetweenTheHandles() async {
        let (model, engine) = makeModel(video)
        await model.open()

        model.moveTrimStart(to: 50)
        model.moveTrimEnd(to: 50.4)
        #expect(model.project.trimRange == TimeRangeCodable(start: 50, duration: 1))

        model.moveTrimStart(to: 80)
        #expect(model.project.trimRange == TimeRangeCodable(start: 50, duration: 1))
        #expect(engine.playbackRange == model.project.trimRange)
        #expect(model.isTrimmed)
    }

    @Test func trimStaysInsideTheSource() async {
        let (model, _) = makeModel(video)
        await model.open()

        model.moveTrimStart(to: -5)
        model.moveTrimEnd(to: 500)

        #expect(model.project.trimRange == TimeRangeCodable(start: 0, duration: 198))
        #expect(!model.isTrimmed)
    }

    @Test func finishingATrimSavesIt() async {
        let (model, _) = makeModel(video)
        await model.open()

        model.moveTrimStart(to: 10)
        model.finishTrim()
        await model.close()

        #expect(await autosaver.scheduled.last?.trimRange.start == 10)
        #expect(await autosaver.flushCount == 1)
    }

    @Test func renameTrimsAndSaves() async {
        let (model, _) = makeModel(audio)
        await model.open()

        model.rename(to: "  Episode 12, final  ")
        model.rename(to: "   ")
        await model.close()

        #expect(model.project.title == "Episode 12, final")
        #expect(await autosaver.scheduled.map(\.title) == ["Episode 12, final"])
    }

    @Test func readOnlyProjectsCanPlayButNotChange() async {
        let (model, engine) = makeModel(audio, readOnly: true)
        await model.open()

        model.rename(to: "New title")
        model.moveTrimStart(to: 30)
        model.togglePlayback()
        await model.close()

        #expect(model.project.title == audio.title)
        #expect(model.project.trimRange == audio.trimRange)
        #expect(await autosaver.scheduled.isEmpty)
        #expect(devices.playbackActivations == 1)
        #expect(!engine.isPlaying, "close pauses")
    }

    @Test func aTrimDragIsOneUndoStep() async {
        let (model, _) = makeModel(video)
        await model.open()

        model.moveTrimStart(to: 5)
        model.moveTrimStart(to: 8)
        model.moveTrimStart(to: 12)
        model.finishTrim()

        #expect(model.history.undoStates.count == 1)
        #expect(model.canUndo)
    }

    @Test func aDragThatEndsWhereItStartedAddsNoStep() async {
        let (model, _) = makeModel(video)
        await model.open()

        model.moveTrimStart(to: 5)
        model.moveTrimStart(to: 0)
        model.finishTrim()

        #expect(!model.canUndo)
    }

    @Test func undoAndRedoRestoreTheTrimAndPlaybackAndSave() async {
        let (model, engine) = makeModel(video)
        await model.open()
        model.moveTrimStart(to: 10)
        model.finishTrim()

        model.undo()
        #expect(model.project.trimRange == video.trimRange)
        #expect(engine.playbackRange == video.trimRange)
        #expect(model.canRedo)

        model.redo()
        #expect(model.project.trimRange.start == 10)
        #expect(engine.playbackRange.start == 10)

        await model.close()
        #expect(await autosaver.scheduled.map(\.trimRange.start) == [10, 0, 10])
    }

    @Test func aNewChangeAfterUndoDiscardsRedo() async {
        let (model, _) = makeModel(video)
        await model.open()
        model.moveTrimStart(to: 10)
        model.finishTrim()
        model.undo()

        model.moveTrimEnd(to: 150)
        model.finishTrim()

        #expect(!model.canRedo)
        #expect(model.canUndo)
    }

    @Test func readOnlyProjectsHaveNoUndo() async {
        let (model, _) = makeModel(video, readOnly: true)
        await model.open()
        model.moveTrimStart(to: 10)
        model.finishTrim()
        #expect(!model.canUndo)
    }
}

