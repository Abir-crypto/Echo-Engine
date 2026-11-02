import EchoCore
import Foundation
import Observation

/// What an export needs from the open editor (SPEC § 11.2).
struct ExportEditor {
    let project: Project
    /// The imported original; video projects only.
    let sourceVideo: URL?
    /// The current AI render, after the one in progress finishes (`EditorModel.audioForExport`).
    let audio: @MainActor () async throws -> URL
    let pausePlayback: @MainActor () -> Void
    /// Stops playback and writes pending changes; runs before a post-export action touches the project's files.
    let close: @MainActor () async -> Void
}

/// The export sheet (SPEC § 11): the choices, remembered per media type, the storage line, then the export itself:
/// wait for enhancements → render, encode, remux → deliver → the post-export action, only once delivery is confirmed.
@MainActor
@Observable
final class ExportModel: Identifiable {
    enum Phase: Equatable {
        case choosing
        /// An AI step is still rendering (user decision: the export waits for it).
        case waitingForEnhancements
        /// 0…1 over render, encode and remux.
        case exporting(Double)
        /// Photos, the Files exporter or the share sheet.
        case delivering
        /// Delivered and the post-export action done; `closesEditor` after clearing the cache or deleting.
        case finished(closesEditor: Bool)
    }

    enum PrimaryAction: Equatable {
        case exportVideo, exportAudio, export
    }

    enum Failure: Equatable {
        case notEnoughSpace(needed: Int64, available: Int64)
        case enhancementsFailed
        case couldNotExport
        case photosDenied
        case couldNotSave
        /// The export was delivered, but deleting the project afterwards failed.
        case couldNotDelete
    }

    let project: Project
    var postAction: PostExportAction = .keepProject
    private(set) var phase: Phase = .choosing
    var failure: Failure?
    /// Free space, measured when the sheet opens and again when the export starts.
    private(set) var availableBytes: Int64?
    /// What "Keep, clear cache" frees: the project's renders.
    private(set) var bytesFreedByClearingCache: Int64?
    /// What "Delete project" frees: its folder and its renders.
    private(set) var bytesFreedByDeleting: Int64?

    private var storedChoices: ExportChoices
    @ObservationIgnored private let editor: ExportEditor
    @ObservationIgnored private let settings: any AppSettingsStore
    @ObservationIgnored private let storage: any StorageEstimating
    @ObservationIgnored private let service: any ExportService
    @ObservationIgnored private let workspace: ExportWorkspace
    @ObservationIgnored private let destinations: [DestinationKind: any ExportDestination]
    @ObservationIgnored private let repository: any ProjectRepository
    @ObservationIgnored private let renders: any RenderCaching
    @ObservationIgnored private let waveforms: any WaveformProviding
    @ObservationIgnored private let fallbackTitle: String
    @ObservationIgnored private var exportTask: Task<Void, Never>?

    init(
        editor: ExportEditor,
        settings: any AppSettingsStore,
        storage: any StorageEstimating,
        service: any ExportService,
        workspace: ExportWorkspace,
        destinations: [DestinationKind: any ExportDestination],
        repository: any ProjectRepository,
        renders: any RenderCaching,
        waveforms: any WaveformProviding,
        fallbackTitle: String
    ) {
        project = editor.project
        self.editor = editor
        self.settings = settings
        self.storage = storage
        self.service = service
        self.workspace = workspace
        self.destinations = destinations
        self.repository = repository
        self.renders = renders
        self.waveforms = waveforms
        self.fallbackTitle = fallbackTitle
        let mediaType = editor.project.mediaType
        storedChoices = Self.normalized(settings.lastExportChoices(for: mediaType) ?? .defaults(for: mediaType), for: mediaType)
    }

    /// The sheet's choices; kept consistent as they change (audio projects export audio only, Photos only takes video,
    /// Custom has a bitrate for AAC and a bit depth otherwise).
    var choices: ExportChoices {
        get { storedChoices }
        set { storedChoices = Self.normalized(newValue, for: project.mediaType) }
    }

    var output: ExportOutput { choices.output(for: project.mediaType) }
    var neededBytes: Int64 { storage.bytesToExport(project, output: output) }
    /// True until free space is known to be short.
    var hasEnoughSpace: Bool { availableBytes.map { $0 >= neededBytes } ?? true }
    /// "Export as" is for video projects only.
    var offersExportKind: Bool { project.mediaType == .video }
    /// Photos takes videos only (SPEC § 11.1).
    var offersPhotos: Bool { output.includesVideo }

    var primaryAction: PrimaryAction {
        switch output {
        case .video: .exportVideo
        case .audioOnly: .exportAudio
        case .both: .export
        }
    }

    var isExporting: Bool {
        switch phase {
        case .waitingForEnhancements, .exporting, .delivering: true
        case .choosing, .finished: false
        }
    }

    /// Free space and what the post-export actions would free.
    func load() async {
        availableBytes = try? storage.availableBytes()
        let cache = ((try? await renders.entries(projectID: project.id)) ?? []).reduce(0) { $0 + $1.bytes }
        bytesFreedByClearingCache = cache
        bytesFreedByDeleting = (try? await repository.diskUsage(id: project.id)).map { $0 + cache }
    }

    /// Runs `export()` until it ends or `cancel()` stops it.
    func start() {
        guard exportTask == nil else { return }
        exportTask = Task { [weak self] in
            await self?.export()
            self?.exportTask = nil
        }
    }

    func cancel() {
        exportTask?.cancel()
    }

    func export() async {
        guard phase == .choosing else { return }
        failure = nil
        settings.setLastExportChoices(choices, for: project.mediaType)
        let output = self.output
        if let available = try? storage.availableBytes() {
            availableBytes = available
            guard available >= neededBytes else {
                failure = .notEnoughSpace(needed: neededBytes, available: available)
                return
            }
        }
        editor.pausePlayback()

        phase = .waitingForEnhancements
        let audio: URL
        do {
            audio = try await editor.audio()
        } catch {
            end(error is CancellationError ? nil : .enhancementsFailed)
            return
        }
        let folder: URL
        do {
            folder = try workspace.makeFolder()
        } catch {
            end(.couldNotExport)
            return
        }
        defer { workspace.remove(folder) }

        phase = .exporting(0)
        let job = ExportJob(
            audio: audio, sourceVideo: editor.sourceVideo, manual: project.editState.manual, trimRange: project.trimRange,
            outputLoudness: project.outputLoudness, output: output, title: project.title, fallbackTitle: fallbackTitle
        )
        let relay = ExportProgressRelay(model: self)
        do {
            let files = try await service.export(job, into: folder, progress: relay.report)
            try Task.checkCancellation()
            phase = .delivering
            guard try await deliver(files) == .delivered else {
                end(nil)
                return
            }
        } catch {
            end(Self.failure(for: error))
            return
        }
        await finishProject()
    }

    fileprivate func exportProgressed(_ fraction: Double) {
        guard case .exporting(let current) = phase else { return }
        phase = .exporting(max(current, min(max(fraction, 0), 1)))
    }

    /// Back to the choices, with the failure to show (none when cancelled).
    private func end(_ failure: Failure?) {
        phase = .choosing
        self.failure = failure
    }

    /// Photos takes the video; with "Both" the audio file then goes to Files (user decision, SPEC § 11.1). Files and
    /// Share get every file at once.
    private func deliver(_ files: ExportedFiles) async throws -> DeliveryOutcome {
        let chosen = choices.destination
        if chosen == .photos, let video = files.video, let photos = destinations[.photos] {
            guard try await photos.deliver([video]) == .delivered else { return .cancelled }
            guard let audio = files.audio, let others = destinations[.files] else { return .delivered }
            return try await others.deliver([audio])
        }
        guard let destination = destinations[chosen] else { throw ExportError.deliveryFailed }
        return try await destination.deliver(files.all)
    }

    /// Only after a confirmed delivery (SPEC § 11.2 step 6). The editor closes first, so nothing writes into the
    /// project while its files go; clearing the cache also returns Home (user decision, SPEC § 11.1).
    private func finishProject() async {
        switch postAction {
        case .keepProject:
            break
        case .keepProjectClearCache:
            await editor.close()
            try? await renders.removeAll(projectID: project.id)
            try? await waveforms.removeAll(projectID: project.id)
        case .deleteProject:
            await editor.close()
            do {
                try await repository.delete(id: project.id)
                try? await renders.removeAll(projectID: project.id)
                try? await waveforms.removeAll(projectID: project.id)
            } catch {
                failure = .couldNotDelete
            }
        }
        phase = .finished(closesEditor: postAction != .keepProject)
    }

    private static func failure(for error: any Error) -> Failure? {
        switch error {
        case is CancellationError: nil
        case ExportError.photoLibraryDenied: .photosDenied
        case ExportError.photoLibraryFailed, ExportError.deliveryFailed: .couldNotSave
        default: .couldNotExport
        }
    }

    private static func normalized(_ choices: ExportChoices, for mediaType: MediaType) -> ExportChoices {
        var choices = choices
        if mediaType != .video { choices.kind = .audioOnly }
        if !choices.output(for: mediaType).includesVideo, choices.destination == .photos { choices.destination = .files }
        if choices.custom.format.isLossless {
            choices.custom.bitrate = nil
            if choices.custom.bitDepth.map(AudioExportSettings.bitDepths.contains) != true { choices.custom.bitDepth = 24 }
        } else {
            choices.custom.bitDepth = nil
            if choices.custom.bitrate.map(AudioExportSettings.aacBitrates.contains) != true {
                choices.custom.bitrate = ExportChoices.defaultVideoAudioBitrate
            }
        }
        if !AudioExportSettings.sampleRates.contains(choices.custom.sampleRate) { choices.custom.sampleRate = 48_000 }
        return choices
    }
}

/// Carries export progress (reported off the main actor) back to the model.
@MainActor
private final class ExportProgressRelay {
    private weak var model: ExportModel?

    init(model: ExportModel) {
        self.model = model
    }

    nonisolated func report(_ fraction: Double) {
        Task { @MainActor in self.model?.exportProgressed(fraction) }
    }
}
