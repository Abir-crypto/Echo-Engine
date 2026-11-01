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
    private let renderer = FakeAIChainRenderer()
    private let janitor = FakeRenderCacheJanitor()

    private func makeModel(
        _ project: Project,
        readOnly: Bool = false,
        engine: FakePlaybackEngine? = nil,
        entitlements: FakeEntitlements = FakeEntitlements(),
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
            entitlements: entitlements,
            capabilities: FakeCapabilities(),
            renderer: renderer,
            janitor: janitor,
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

    @Test func openingAppliesTheProjectsManualSettings() async {
        var project = audio
        project.clips[0].manual.inputGainDB = 4
        let (model, engine) = makeModel(project)
        await model.open()
        #expect(engine.appliedManual?.inputGainDB == 4)
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

    @Test(arguments: [AudioSessionEvent.interruptionBegan, .outputDeviceRemoved])
    func interruptionsAndLostOutputsPause(_ event: AudioSessionEvent) async {
        let (model, engine) = makeModel(audio)
        await model.open()
        model.togglePlayback()

        devices.send(event)
        await waitUntil { !engine.isPlaying }

        #expect(!engine.isPlaying)
        await model.close()
    }

    @Test func theEndOfAnInterruptionDoesNotResume() async {
        let (model, engine) = makeModel(audio)
        await model.open()
        model.togglePlayback()
        devices.send(.interruptionBegan)
        await waitUntil { !engine.isPlaying }

        devices.send(.interruptionEnded)
        for _ in 0..<10 { await Task.yield() }

        #expect(!engine.isPlaying)
        model.togglePlayback()
        #expect(engine.isPlaying, "the next Play starts again")
        await model.close()
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
        }
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

    @Test func aTrimDragWhilePlayingReachesTheEngineWhenItEnds() async {
        let (model, engine) = makeModel(video)
        await model.open()
        model.togglePlayback()

        model.moveTrimEnd(to: 120)
        model.moveTrimEnd(to: 100)
        #expect(engine.playbackRange == video.trimRange, "the playing audio isn't restarted per drag step")

        model.finishTrim()
        #expect(engine.playbackRange == TimeRangeCodable(start: 0, duration: 100))
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

    @Test func readOnlyProjectsDisableEveryControl() async {
        let (model, engine) = makeModel(audio, readOnly: true)
        await model.open()

        model.rename(to: "New title")
        model.moveTrimStart(to: 30)
        model.togglePlayback()
        model.seek(to: 12)
        model.holdOriginal(true)
        await model.close()

        #expect(model.project.title == audio.title)
        #expect(model.project.trimRange == audio.trimRange)
        #expect(await autosaver.scheduled.isEmpty)
        #expect(devices.playbackActivations == 0)
        #expect(!engine.isPlaying)
        #expect(engine.currentTime == 0)
        #expect(!model.isHoldingOriginal)
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

    @Test func adjustingIsHeardAtOnceAndOneUndoStepWhenFinished() async {
        let (model, engine) = makeModel(audio)
        await model.open()

        model.adjust { $0.inputGainDB = 1 }
        model.adjust { $0.inputGainDB = 2.5 }
        #expect(engine.appliedManual?.inputGainDB == 2.5)
        #expect(!model.canUndo, "nothing is recorded mid-drag")

        model.finishAdjusting()
        #expect(model.history.undoStates.count == 1)
        await model.close()
        #expect(await autosaver.scheduled.last?.clips[0].manual.inputGainDB == 2.5)

        model.undo()
        #expect(model.manual.inputGainDB == 0)
        #expect(engine.appliedManual?.inputGainDB == 0, "undo is heard too")
    }

    @Test func resettingTheEqualizerIsOneStep() async {
        let (model, _) = makeModel(audio)
        await model.open()
        model.adjust { $0.eq[2].gainDB = 6 }
        model.finishAdjusting()

        model.resetEqualizer()

        #expect(model.manual.eq == EQBand.defaultBands)
        #expect(model.history.undoStates.count == 2)
    }

    @Test func holdingForTheOriginalBypassesTheChainUntilReleased() async {
        let (model, engine) = makeModel(audio)
        await model.open()

        model.holdOriginal(true)
        #expect(model.isHoldingOriginal)
        #expect(engine.isHoldingOriginal)

        model.holdOriginal(false)
        #expect(!engine.isHoldingOriginal)
    }

    @Test func readOnlyProjectsCannotBeAdjusted() async {
        let (model, engine) = makeModel(audio, readOnly: true)
        await model.open()
        model.adjust { $0.inputGainDB = 6 }
        #expect(model.manual.inputGainDB == 0)
        #expect(engine.appliedManual?.inputGainDB == 0)
    }

    // MARK: AI renders (F06.T06)

    private var noise: AIOperation { AIOperation(kind: .noiseSuppression, strength: 1) }
    private var clear: AIOperation { AIOperation(kind: .clearVoice, strength: 0.5) }
    /// The audio sample without its AI step.
    private var plain: Project {
        var project = audio
        project.clips[0].aiStack = []
        return project
    }

    private func render(_ steps: Int, of project: Project) -> URL {
        FakeAIChainRenderer.renderURL(source: repository.folder(for: project.id).working, steps: steps)
    }

    @Test func withoutAIStepsTheOriginalPlaysAndNothingRenders() async {
        let (model, engine) = makeModel(plain)
        await model.open()
        #expect(engine.currentAudio == repository.folder(for: plain.id).working)
        #expect(await renderer.chains.isEmpty)
    }

    @Test func openingRendersTheStackThenSwapsToIt() async {
        var project = audio
        project.clips[0].aiStack = [noise, clear]
        let (model, engine) = makeModel(project)

        await model.open()
        await waitUntil { engine.currentAudio == render(2, of: project) }

        #expect(engine.loadedAudio == repository.folder(for: project.id).working, "plays the original until the render is ready")
        #expect(engine.swappedAudio == [render(2, of: project)])
        #expect(await renderer.chains.map(\.operations.count) == [2])
        #expect(model.renderProgress == nil)
    }

    @Test func changingTheStackIsOneStepRendersAndSweeps() async {
        let (model, engine) = makeModel(plain)
        await model.open()

        model.changeAIStack { $0.append(noise) }
        await waitUntil { engine.currentAudio == render(1, of: plain) }

        #expect(model.aiStack.map(\.kind) == [.noiseSuppression])
        #expect(model.history.undoStates.count == 1)
        #expect(await janitor.sweeps.last?.current.aiStack.count == 1)
        await model.close()
        #expect(await autosaver.scheduled.last?.clips[0].aiStack.count == 1)
    }

    @Test func undoRendersThePreviousStack() async {
        let (model, engine) = makeModel(plain)
        await model.open()
        model.changeAIStack { $0.append(noise) }
        await waitUntil { engine.currentAudio == render(1, of: plain) }

        model.undo()
        await waitUntil { engine.currentAudio == repository.folder(for: plain.id).working }

        #expect(model.aiStack.isEmpty)
        #expect(engine.currentAudio == repository.folder(for: plain.id).working)
    }

    @Test func holdingForTheOriginalPlaysWorkingAudioUntilReleased() async {
        var project = audio
        project.clips[0].aiStack = [noise]
        let (model, engine) = makeModel(project)
        await model.open()
        await waitUntil { engine.currentAudio == render(1, of: project) }

        model.holdOriginal(true)
        #expect(engine.currentAudio == repository.folder(for: project.id).working)
        #expect(engine.isHoldingOriginal)

        model.holdOriginal(false)
        #expect(engine.currentAudio == render(1, of: project))
    }

    @Test func auditioningAStepPlaysItsPrefixUntilTappedAgain() async {
        var project = audio
        project.clips[0].aiStack = [noise, clear]
        let (model, engine) = makeModel(project)
        await model.open()
        await waitUntil { engine.currentAudio == render(2, of: project) }

        model.audition(step: 0)
        #expect(model.auditionedStep == 0)
        #expect(engine.currentAudio == render(1, of: project))

        model.audition(step: 0)
        #expect(model.auditionedStep == nil)
        #expect(engine.currentAudio == render(2, of: project))
    }

    @Test func aFailedRenderIsReportedAndPlaybackStaysOnTheOriginal() async {
        await renderer.setError(RenderError.cantWrite)
        let (model, engine) = makeModel(plain)
        await model.open()

        model.changeAIStack { $0.append(noise) }
        await waitUntil { model.failure != nil }

        #expect(model.failure == .cantRender)
        #expect(engine.currentAudio == repository.folder(for: plain.id).working)
    }

    @Test func addingAFeaturePutsItLastAtEightyPercent() async {
        let (model, _) = makeModel(plain)
        await model.open()

        model.addEnhancement(.noiseSuppression)
        model.addEnhancement(.clearVoice)

        #expect(model.aiStack.map(\.kind) == [.noiseSuppression, .clearVoice])
        #expect(model.aiStack.allSatisfy { $0.strength == 0.8 })
        #expect(EditorModel.offeredFeatures == [.noiseSuppression, .clearVoice, .voiceLeveler])
        model.addEnhancement(.voiceLeveler)
        #expect(model.aiStack.last?.kind == .voiceLeveler)
        #expect(model.history.undoStates.count == 3)
        #expect(model.showsAlreadyReducesNoise(at: 1))
        #expect(!model.showsAlreadyReducesNoise(at: 0))
    }

    @Test func eachFeatureOnceAndOnlyWhenAvailable() async {
        let (model, _) = makeModel(plain, entitlements: FakeEntitlements(locked: [.clearVoice]))
        await model.open()
        model.addEnhancement(.noiseSuppression)

        #expect(!model.canAdd(.noiseSuppression), "already in the stack")
        #expect(!model.isAvailable(.clearVoice))
        model.addEnhancement(.clearVoice)
        #expect(model.aiStack.count == 1)
        #expect(!model.isAvailable(.unknown))
    }

    @Test func removingMovingAndStrengthAreEachOneStep() async {
        var project = plain
        project.clips[0].aiStack = [noise, clear]
        let (model, _) = makeModel(project)
        await model.open()

        model.moveEnhancements(fromOffsets: [1], toOffset: 0)
        #expect(model.aiStack.map(\.kind) == [.clearVoice, .noiseSuppression])
        model.setStrength(0.35, at: 1)
        #expect(model.aiStack[1].strength == 0.35)
        model.removeEnhancement(at: 0)
        #expect(model.aiStack.map(\.kind) == [.noiseSuppression])
        #expect(model.history.undoStates.count == 3)

        model.undo()
        model.undo()
        model.undo()
        #expect(model.aiStack.map(\.kind) == [.noiseSuppression, .clearVoice])
    }

    @Test func theRenderingStepShowsProgressUntilDone() async {
        await renderer.setDelay(.milliseconds(200))
        let (model, engine) = makeModel(plain)
        await model.open()

        model.addEnhancement(.noiseSuppression)
        await waitUntil { model.renderingStep != nil }
        #expect(model.renderingStep == 0)
        #expect(model.renderProgress == 0)

        for _ in 0..<50 where engine.currentAudio != render(1, of: plain) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.renderingStep == nil)
        #expect(model.renderProgress == nil)
    }

    @Test func closingPrunesToTheCurrentRenders() async {
        let (model, _) = makeModel(plain)
        await model.open()
        model.changeAIStack { $0.append(noise) }

        await model.close()

        #expect(await janitor.prunes.map(\.aiStack.count) == [1])
    }

    @Test func readOnlyProjectsHaveNoUndo() async {
        let (model, _) = makeModel(video, readOnly: true)
        await model.open()
        model.moveTrimStart(to: 10)
        model.finishTrim()
        #expect(!model.canUndo)
    }
}

