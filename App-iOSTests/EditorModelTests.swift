import EchoCore
import EchoCoreFakes
@testable import EchoEngine
import Foundation
import Testing

private struct LoadFailure: Error {}

@MainActor
final class EditorModelTests {
    private let video = PreviewProjects.all()[0]   // 198 s video
    private let audio = PreviewProjects.all()[1]   // audio
    private let devices = FakeAudioDeviceManager()
    private let autosaver = FakeProjectAutosaver()
    private let repository = FakeProjectRepository()
    private let renderer = FakeAIChainRenderer()
    private let janitor = FakeRenderCacheJanitor()
    private let autoLevel = FakeAutoLevelAnalyzer()
    private let clock = FakeClock(now: Date(timeIntervalSince1970: 1_900_000_000))
    private let podcastVoice = Preset(
        id: BuiltInPresetID.podcastVoice, name: "Podcast Voice",
        aiStack: [AIOperation(kind: .noiseSuppression, strength: 0.7), AIOperation(kind: .voiceLeveler, strength: 1)],
        manual: ManualSettings(), outputLoudness: .podcast, isBuiltIn: true, createdAt: Date(timeIntervalSince1970: 0)
    )
    private var presets: FakePresetRepository!

    private func makeModel(
        _ project: Project,
        readOnly: Bool = false,
        engine: FakePlaybackEngine? = nil,
        entitlements: FakeEntitlements = FakeEntitlements(),
        storage: FakeStorageEstimator = FakeStorageEstimator(editBytes: 1_000, available: 1_000_000),
        presets: FakePresetRepository? = nil
    ) -> (EditorModel, FakePlaybackEngine) {
        let engine = engine ?? FakePlaybackEngine(duration: project.sourceInfo.duration)
        let presets = presets ?? FakePresetRepository(builtIns: [podcastVoice])
        self.presets = presets
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
            autoLevel: autoLevel,
            presets: presets,
            clock: clock,
            autoLevelDelay: .milliseconds(5),
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

    @Test func exportWaitsForTheRunningRenderAndUsesIt() async throws {
        await renderer.setDelay(.milliseconds(100))
        var project = audio
        project.clips[0].aiStack = [noise, clear]
        let (model, _) = makeModel(project)
        await model.open()

        #expect(try await model.audioForExport() == render(2, of: project))
    }

    @Test func withoutAIStepsExportUsesTheWorkingAudio() async throws {
        let (model, _) = makeModel(plain)
        await model.open()

        #expect(try await model.audioForExport() == repository.folder(for: plain.id).working)
    }

    @Test func exportNeverUsesARenderOfAnOlderStack() async throws {
        let (model, _) = makeModel(plain)
        await model.open()
        await renderer.setError(RenderError.cantWrite)

        model.changeAIStack { $0.append(noise) }
        await waitUntil { model.failure != nil }

        await #expect(throws: ExportError.unreadableAudio) { try await model.audioForExport() }
    }

    // MARK: Presets

    @Test func applyingAPresetReplacesTheSettingsInOneUndoStep() async {
        var project = plain
        project.clips[0].manual.inputGainDB = 5
        project.trimRange = TimeRangeCodable(start: 1, duration: 10)
        let (model, engine) = makeModel(project)
        await model.open()

        model.applyPreset(podcastVoice)

        #expect(model.aiStack.map(\.kind) == [.noiseSuppression, .voiceLeveler])
        #expect(model.aiStack.map(\.strength) == [0.7, 1])
        #expect(Set(model.aiStack.map(\.id)).isDisjoint(with: podcastVoice.aiStack.map(\.id)), "copied, not linked")
        #expect(model.manual == ManualSettings())
        #expect(engine.appliedManual == ManualSettings())
        #expect(model.outputLoudness == .podcast)
        #expect(model.project.trimRange == TimeRangeCodable(start: 1, duration: 10), "presets never carry a trim")
        #expect(model.project.basePresetID == podcastVoice.id)

        model.undo()
        #expect(model.aiStack.isEmpty)
        #expect(model.manual.inputGainDB == 5)
        #expect(model.outputLoudness == nil)
        #expect(!model.canUndo, "one step")
    }

    @Test func theProjectSaysWhichPresetItIsBasedOnAndWhenItChanged() async {
        let (model, _) = makeModel(plain)
        await model.open()
        #expect(model.basePreset == nil)

        model.applyPreset(podcastVoice)
        #expect(model.basePreset?.id == podcastVoice.id)
        #expect(!model.isModifiedFromBasePreset)

        model.changeAIStack { $0[0].strength = 0.5 }
        #expect(model.isModifiedFromBasePreset)
        #expect(!model.canUpdateBasePreset, "built-ins can't be updated")
    }

    @Test func saveAsPresetKeepsTheCurrentSettingsAndBasesTheProjectOnIt() async throws {
        var project = plain
        project.clips[0].aiStack = [noise]
        project.clips[0].manual.inputGainDB = 4
        project.outputLoudness = .youtube
        let (model, _) = makeModel(project)
        await model.open()

        await model.saveAsPreset(named: "  Booth  ")

        let saved = try #require(await presets.saved.values.first)
        #expect(saved.name == "Booth")
        #expect(!saved.isBuiltIn)
        #expect(saved.aiStack.map(\.kind) == [.noiseSuppression])
        #expect(saved.manual.inputGainDB == 4)
        #expect(saved.outputLoudness == .youtube)
        #expect(saved.createdAt == clock.now)
        #expect(model.project.basePresetID == saved.id)
        #expect(model.basePreset?.name == "Booth")
        #expect(model.canUpdateBasePreset)
    }

    @Test func updatePresetWritesTheCurrentSettingsIntoIt() async throws {
        let mine = Preset(name: "Booth", aiStack: [noise], manual: ManualSettings(), outputLoudness: nil, createdAt: Date(timeIntervalSince1970: 0))
        let (model, _) = makeModel(plain, presets: FakePresetRepository(builtIns: [podcastVoice], saved: [mine]))
        await model.open()
        model.applyPreset(mine)
        model.setOutputLoudness(.spotify)
        #expect(model.isModifiedFromBasePreset)

        await model.updateBasePreset()

        let updated = try #require(await presets.saved[mine.id])
        #expect(updated.outputLoudness == .spotify)
        #expect(updated.updatedAt == clock.now)
        #expect(!model.isModifiedFromBasePreset)
    }

    @Test func aPresetThatCantBeSavedIsReported() async {
        let (model, _) = makeModel(plain)
        await model.open()
        await presets.setError(CocoaError(.fileWriteOutOfSpace))

        await model.saveAsPreset(named: "Booth")

        #expect(model.failure == .cantSavePreset)
        #expect(model.project.basePresetID == nil)
    }

    @Test func readOnlyProjectsTakeNoPreset() async {
        let (model, _) = makeModel(plain, readOnly: true)
        await model.open()

        model.applyPreset(podcastVoice)

        #expect(model.aiStack.isEmpty)
        #expect(model.project.basePresetID == nil)
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

    // MARK: Auto Level (F07.T03)

    private func waitForAutoLevel(_ count: Int) async {
        for _ in 0..<100 where await autoLevel.requests.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(20))
    }

    @Test func autoLevelIsOffByDefault() async {
        let (model, engine) = makeModel(plain)
        await model.open()
        try? await Task.sleep(for: .milliseconds(30))

        #expect(await autoLevel.requests.isEmpty)
        #expect(model.autoLevelGainDB == nil)
        #expect(engine.autoLevelGainDB == 0)
    }

    @Test func aTargetMeasuresTheProcessedAudioOverTheTrim() async {
        let (model, engine) = makeModel(plain)
        await model.open()
        model.moveTrimStart(to: 2)
        model.finishTrim()

        model.setOutputLoudness(.youtube)
        await waitForAutoLevel(1)

        let request = await autoLevel.requests.last
        #expect(request?.audio == repository.folder(for: plain.id).working)
        #expect(request?.range.start == 2)
        #expect(request?.target == .youtube)
        #expect(model.autoLevelGainDB == 4)
        #expect(engine.autoLevelGainDB == 4)
        #expect(model.history.undoStates.count == 2, "trim, then the target")
    }

    @Test func manualChangesAreMeasuredOnceTheySettle() async {
        var project = plain
        project.outputLoudness = .podcast
        let (model, _) = makeModel(project)
        await model.open()
        await waitForAutoLevel(1)

        model.adjust { $0.inputGainDB = 1 }
        model.adjust { $0.inputGainDB = 2 }
        model.adjust { $0.inputGainDB = 3 }
        await waitForAutoLevel(2)

        let requests = await autoLevel.requests
        #expect(requests.count == 2, "three quick changes, one measurement")
        #expect(requests.last?.manual.inputGainDB == 3)
    }

    @Test func autoLevelWaitsForTheRenderAndMeasuresIt() async {
        var project = plain
        project.outputLoudness = .youtube
        project.clips[0].aiStack = [noise]
        let (model, _) = makeModel(project)
        await model.open()
        await waitForAutoLevel(1)

        #expect(await autoLevel.requests.map(\.audio) == [render(1, of: project)])
        #expect(model.autoLevelGainDB == 4)
    }

    @Test func turningTheTargetOffResetsTheGainAndUndoBringsItBack() async {
        let (model, engine) = makeModel(plain)
        await model.open()
        model.setOutputLoudness(.spotify)
        await waitForAutoLevel(1)

        model.setOutputLoudness(nil)
        #expect(model.autoLevelGainDB == nil)
        #expect(engine.autoLevelGainDB == 0)

        model.undo()
        await waitForAutoLevel(2)
        #expect(model.outputLoudness == .spotify)
        #expect(engine.autoLevelGainDB == 4)
    }

    @Test func aCustomTargetIsRemeasuredWhenItChangesAndTheSameChoiceAddsNoStep() async {
        let (model, engine) = makeModel(plain)
        await model.open()
        model.setOutputLoudness(.custom(lufs: -14))
        await waitForAutoLevel(1)

        model.setOutputLoudness(.custom(lufs: -14))
        model.setOutputLoudness(.custom(lufs: -23.5))
        await waitForAutoLevel(2)

        #expect(await autoLevel.requests.map(\.target) == [.custom(lufs: -14), .custom(lufs: -23.5)])
        #expect(model.outputLoudness == .custom(lufs: -23.5))
        #expect(model.history.undoStates.count == 2, "the repeated -14 adds no step")
        #expect(engine.autoLevelGainDB == 4)
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

