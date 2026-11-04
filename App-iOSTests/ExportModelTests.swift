import EchoCore
import EchoCoreFakes
@testable import EchoEngine
import Foundation
import Testing

/// Records what the editor was asked to do, and whether the project was still there when it closed.
@MainActor
private final class EditorHooks {
    var pauses = 0
    var closes = 0
    var projectExistedWhenClosed: Bool?
}

@MainActor
private final class PhaseRecorder {
    var phase: ExportModel.Phase?
}

@MainActor
final class ExportModelTests {
    private let video = PreviewProjects.all()[0]
    private let audio = PreviewProjects.all()[1]
    private let settings = FakeAppSettingsStore()
    private let service = FakeExportService()
    private let photos = FakeExportDestination(kind: .photos)
    private let files = FakeExportDestination(kind: .files)
    private let share = FakeExportDestination(kind: .share)
    private let renders = FakeRenderCache()
    private let waveforms = FakeWaveformProvider()
    private let hooks = EditorHooks()
    private let background = FakeBackgroundProcessing()
    private let workspaceRoot = FileManager.default.temporaryDirectory.appending(path: "ExportModelTests-\(UUID().uuidString)")
    private let renderedAudio = URL(filePath: "/tmp/render-2.m4a")
    private let analytics = FakeAnalytics()
    private var repository: FakeProjectRepository!

    deinit {
        try? FileManager.default.removeItem(at: workspaceRoot)
    }

    private func makeModel(
        _ project: Project,
        storage: FakeStorageEstimator = FakeStorageEstimator(exportBytes: 1_200, available: 18_400),
        audio: (@MainActor () async throws -> URL)? = nil
    ) -> ExportModel {
        let repository = FakeProjectRepository(projects: [project], diskUsageByID: [project.id: 1_400])
        self.repository = repository
        let hooks = self.hooks
        let rendered = renderedAudio
        let editor = ExportEditor(
            project: project,
            sourceVideo: project.mediaType == .video ? URL(filePath: "/tmp/source.mov") : nil,
            audio: audio ?? { rendered },
            pausePlayback: { hooks.pauses += 1 },
            close: {
                hooks.projectExistedWhenClosed = await repository.stored[project.id] != nil
                hooks.closes += 1
            }
        )
        return ExportModel(
            editor: editor,
            settings: settings,
            storage: storage,
            service: service,
            workspace: ExportWorkspace(root: workspaceRoot),
            destinations: [.photos: photos, .files: files, .share: share],
            repository: repository,
            renders: renders,
            waveforms: waveforms,
            background: background,
            fallbackTitle: "Echo Engine export",
            analytics: analytics
        )
    }

    // MARK: Analytics (SPEC § 16)

    @Test func anExportIsCountedByItsChoicesOnly() async {
        let model = makeModel(audio)
        let format = model.output.audioSettings?.format
        await model.export()
        #expect(analytics.events == [
            .exportStarted(output: .audioOnly, format: format),
            .exportCompleted(output: .audioOnly, format: format, destination: .files, postAction: .keepProject),
        ])
    }

    @Test func tooLittleSpaceIsCountedAsBlocked() async {
        let model = makeModel(video, storage: FakeStorageEstimator(exportBytes: 20_000, available: 18_400))
        await model.export()
        #expect(analytics.events == [.exportFailed(reason: .notEnoughSpace), .storageBlocked(stage: .export)])
    }

    // MARK: Choices

    @Test func firstExportsStartFromTheDefaults() {
        let model = makeModel(video)
        #expect(model.choices == .defaults(for: .video))
        #expect(model.output == .video(audioBitrate: 320_000))
        #expect(model.primaryAction == .exportVideo)
    }

    @Test func theLastChoicesForTheMediaTypeComeBack() {
        var last = ExportChoices.defaults(for: .video)
        last.kind = .both
        last.destination = .share
        settings.setLastExportChoices(last, for: .video)

        let model = makeModel(video)

        #expect(model.choices == last)
        #expect(model.primaryAction == .export)
    }

    @Test func audioProjectsExportAudioAndNeverToPhotos() {
        let model = makeModel(audio)
        #expect(!model.offersExportKind)
        #expect(!model.offersPhotos)
        #expect(model.primaryAction == .exportAudio)

        model.choices.destination = .photos
        #expect(model.choices.destination == .files)
    }

    @Test func choosingAudioOnlyLeavesPhotos() {
        let model = makeModel(video)
        #expect(model.choices.destination == .photos)

        model.choices.kind = .audioOnly

        #expect(model.choices.destination == .files)
        #expect(model.primaryAction == .exportAudio)
    }

    @Test func customFormatsKeepMatchingSettings() {
        let model = makeModel(audio)
        model.choices.quality = .custom

        model.choices.custom.format = .wav
        #expect(model.choices.custom.bitrate == nil)
        #expect(model.choices.custom.bitDepth == 24)

        model.choices.custom.format = .aac
        #expect(model.choices.custom.bitDepth == nil)
        #expect(model.choices.custom.bitrate == 256_000)
    }

    // MARK: Storage

    @Test func theStorageLineHasExactNumbers() async {
        let model = makeModel(video)
        await model.load()
        #expect(model.neededBytes == 1_200)
        #expect(model.availableBytes == 18_400)
        #expect(model.hasEnoughSpace)
        #expect(model.bytesFreedByDeleting == 1_400)
        #expect(model.bytesFreedByClearingCache == 0)
    }

    @Test func tooLittleSpaceStopsTheExportWithExactNumbers() async {
        let model = makeModel(video, storage: FakeStorageEstimator(exportBytes: 2_400, available: 1_100))
        await model.load()
        #expect(!model.hasEnoughSpace)

        await model.export()

        #expect(model.failure == .notEnoughSpace(needed: 2_400, available: 1_100))
        #expect(await service.jobs.isEmpty)
    }

    // MARK: Export

    @Test func anExportMakesTheJobDeliversItAndRemembersTheChoices() async throws {
        var project = video
        project.trimRange = TimeRangeCodable(start: 2, duration: 30)
        project.outputLoudness = .youtube
        let model = makeModel(project)
        model.choices.quality = .standard

        await model.export()

        let job = try #require(await service.jobs.first)
        #expect(job.audio == renderedAudio)
        #expect(job.sourceVideo == URL(filePath: "/tmp/source.mov"))
        #expect(job.trimRange == project.trimRange)
        #expect(job.outputLoudness == .youtube)
        #expect(job.output == .video(audioBitrate: 192_000))
        #expect(job.title == project.title)
        #expect(await photos.delivered.map { $0.map(\.pathExtension) } == [["mov"]])
        #expect(model.phase == .finished(closesEditor: false))
        #expect(settings.lastExportChoices(for: .video)?.quality == .standard)
        #expect(hooks.pauses == 1)
        #expect(hooks.closes == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspaceRoot.path(percentEncoded: false)).isEmpty, "temp files removed")
    }

    @Test func bothToPhotosSendsTheVideoThereAndTheAudioToFiles() async {
        let model = makeModel(video)
        model.choices.kind = .both

        await model.export()

        #expect(await photos.delivered.map { $0.map(\.pathExtension) } == [["mov"]])
        #expect(await files.delivered.map { $0.map(\.pathExtension) } == [["m4a"]])
        #expect(model.phase == .finished(closesEditor: false))
    }

    @Test func bothToShareSendsBothFilesTogether() async {
        let model = makeModel(video)
        model.choices.kind = .both
        model.choices.destination = .share

        await model.export()

        #expect(await share.delivered.map { $0.map(\.pathExtension) } == [["mov", "m4a"]])
    }

    @Test func theExportWaitsForEnhancements() async {
        let gate = AsyncStream<Void>.makeStream()
        let rendered = renderedAudio
        let model = makeModel(audio) {
            for await _ in gate.stream { break }
            return rendered
        }

        let task = Task { await model.export() }
        while model.phase != .waitingForEnhancements { await Task.yield() }
        gate.continuation.yield()
        await task.value

        #expect(model.phase == .finished(closesEditor: false))
        #expect(await service.jobs.first?.audio == rendered)
    }

    // MARK: After export

    @Test func deletingClosesTheEditorThenRemovesTheProjectAndItsCaches() async {
        let model = makeModel(video)
        model.postAction = .deleteProject

        await model.export()

        #expect(hooks.closes == 1)
        #expect(hooks.projectExistedWhenClosed == true, "the editor saved and closed before the delete")
        #expect(await repository.stored[video.id] == nil)
        #expect(await renders.removedAllProjectIDs == [video.id])
        #expect(await waveforms.removedProjectIDs == [video.id])
        #expect(model.phase == .finished(closesEditor: true))
    }

    @Test func clearingTheCacheKeepsTheProjectAndClosesTheEditor() async {
        let model = makeModel(video)
        model.postAction = .keepProjectClearCache

        await model.export()

        #expect(hooks.closes == 1)
        #expect(await repository.stored[video.id] != nil)
        #expect(await renders.removedAllProjectIDs == [video.id])
        #expect(model.phase == .finished(closesEditor: true))
    }

    @Test func nothingHappensToTheProjectWhenDeliveryIsCancelled() async {
        await photos.setOutcome(.cancelled)
        let model = makeModel(video)
        model.postAction = .deleteProject

        await model.export()

        #expect(hooks.closes == 0)
        #expect(await repository.stored[video.id] != nil)
        #expect(model.phase == .choosing)
        #expect(model.failure == nil)
    }

    // MARK: Failures

    @Test func deniedPhotosAccessIsExplained() async {
        await photos.setError(ExportError.photoLibraryDenied)
        let model = makeModel(video)
        model.postAction = .deleteProject

        await model.export()

        #expect(model.failure == .photosDenied)
        #expect(model.phase == .choosing)
        #expect(await repository.stored[video.id] != nil)
    }

    @Test func aFailedExportIsReportedAndCleanedUp() async throws {
        await service.setError(ExportError.cantWrite)
        let model = makeModel(audio)

        await model.export()

        #expect(model.failure == .couldNotExport)
        #expect(model.phase == .choosing)
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspaceRoot.path(percentEncoded: false)).isEmpty)
    }

    @Test func enhancementsThatFailedToRenderAreReported() async {
        let model = makeModel(audio) { throw ExportError.unreadableAudio }

        await model.export()

        #expect(model.failure == .enhancementsFailed)
        #expect(await service.jobs.isEmpty)
    }

    // MARK: Background

    @Test func theExportRunsAsABackgroundActivityUntilItsFilesAreReady() async throws {
        let model = makeModel(video)
        let ended = PhaseRecorder()
        background.onActivityFinished = { _ in ended.phase = model.phase }

        await model.export()

        let activity = try #require(background.activities.first)
        #expect(background.activities.count == 1)
        #expect(!activity.title.isEmpty)
        #expect(activity.progress.last == 1)
        #expect(activity.result == true)
        #expect(ended.phase == .exporting(1), "it ends before delivery: Photos, Files and Share need the person")
    }

    @Test func aFailedExportEndsTheActivityUnsuccessfully() async throws {
        await service.setError(ExportError.cantWrite)
        let model = makeModel(audio)

        await model.export()

        #expect(try #require(background.activities.first).result == false)
    }

    @Test func whenTheSystemStopsTheExportItIsCancelledAndExplained() async throws {
        await service.setDelay(.seconds(10))
        let model = makeModel(audio)

        model.start()
        while await service.jobs.isEmpty { await Task.yield() }
        try #require(background.activities.first).stop()
        while model.phase != .choosing { await Task.yield() }

        #expect(model.failure == .stoppedInBackground)
        #expect(try #require(background.activities.first).result == false)
        #expect(await files.delivered.isEmpty)
    }

    @Test func withoutBackgroundTimeTheExportRunsInTheForeground() async {
        background.allowsBackground = false
        let model = makeModel(audio)

        await model.export()

        #expect(model.phase == .finished(closesEditor: false))
        #expect(background.activities.isEmpty)
    }

    @Test func cancellingStopsTheExportQuietly() async {
        await service.setDelay(.seconds(10))
        let model = makeModel(audio)

        model.start()
        while await service.jobs.isEmpty { await Task.yield() }
        model.cancel()
        while model.phase != .choosing { await Task.yield() }

        #expect(model.failure == nil)
        #expect(await files.delivered.isEmpty)
        #expect(background.activities.first?.result == false)
    }
}
