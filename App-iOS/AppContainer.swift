import EchoCore
import Foundation
import Observation

/// Composition root: the only place that names concrete service types (SPEC § 4.4).
/// Injected into SwiftUI with `.environment(_:)`; tests and previews pass fakes to `init`.
@MainActor
@Observable
final class AppContainer {
    let entitlements: any EntitlementProvider
    let capabilities: any DeviceCapabilityChecking
    let projects: any ProjectRepository
    let inspector: any MediaInspecting
    let importer: any MediaImporting
    let storage: any StorageEstimating
    let dateProvider: any DateProviding
    let devices: any AudioDeviceManaging
    let waveforms: any WaveformProviding
    let renders: any RenderCaching
    let renderer: any AIChainRendering
    let janitor: any RenderCacheJanitoring
    let autoLevel: any AutoLevelAnalyzing
    let exportWorkspace: ExportWorkspace
    /// Shows Files and Share deliveries (SPEC § 11.2 step 5).
    let deliveryPresenter: DeliveryPresenter
    let destinations: [DestinationKind: any ExportDestination]
    let settings: any AppSettingsStore
    let exportService: any ExportService
    let background: any BackgroundProcessing
    let presets: any PresetRepository
    let idleTimer: any IdleTimerControlling
    let recordingActivity: any RecordingActivityPresenting
    /// The recording Live Activity's Stop reaches the app through this (registered with `AppDependencyManager`).
    let recordingStopRelay = RecordingStopRelay()
    /// Makes recorded projects from takes: on Stop and when recovering (SPEC § 13.3).
    let recordedProjects: any RecordedProjectBuilding
    let recovery: any RecordingRecovering

    init(
        entitlements: any EntitlementProvider = FreeV1Entitlements(),
        capabilities: any DeviceCapabilityChecking = DefaultCapabilities(),
        projects: any ProjectRepository = FileProjectRepository(root: .projectsDirectory, migrator: ProjectMigrator()),
        inspector: any MediaInspecting = AVMediaInspector(),
        importer: any MediaImporting = AVMediaImporter(),
        storage: any StorageEstimating = StorageEstimator(volume: .documentsDirectory),
        dateProvider: any DateProviding = SystemClock(),
        devices: any AudioDeviceManaging = IOSAudioDeviceManager(),
        waveforms: any WaveformProviding = CachedWaveformProvider(root: .waveformCacheDirectory),
        renders: any RenderCaching = FileRenderCache(root: .renderCacheDirectory),
        renderer: (any AIChainRendering)? = nil,
        janitor: (any RenderCacheJanitoring)? = nil,
        autoLevel: any AutoLevelAnalyzing = AutoLevelAnalyzer(),
        exportWorkspace: ExportWorkspace = ExportWorkspace(root: .exportTemporaryDirectory),
        photoLibrary: any PhotoLibraryAdding = SystemPhotoLibrary(),
        settings: (any AppSettingsStore)? = nil,
        exportService: (any ExportService)? = nil,
        background: (any BackgroundProcessing)? = nil,
        presets: (any PresetRepository)? = nil,
        idleTimer: any IdleTimerControlling = UIKitIdleTimer(),
        recordingActivity: any RecordingActivityPresenting = LiveRecordingActivity(),
        recordedProjects: (any RecordedProjectBuilding)? = nil,
        recovery: (any RecordingRecovering)? = nil
    ) {
        self.entitlements = entitlements
        self.capabilities = capabilities
        self.projects = projects
        self.inspector = inspector
        self.importer = importer
        self.storage = storage
        self.dateProvider = dateProvider
        self.devices = devices
        self.waveforms = waveforms
        self.renders = renders
        self.renderer = renderer ?? AIChainRenderer(processor: AIProcessorRouter(processors: Self.aiProcessors), cache: renders)
        self.janitor = janitor ?? RenderCacheJanitor(cache: renders, storage: storage, waveforms: waveforms)
        self.autoLevel = autoLevel
        self.exportWorkspace = exportWorkspace
        self.settings = settings ?? UserDefaultsSettingsStore(defaults: .standard)
        self.exportService = exportService ?? AVExportService(
            renderer: FinalRenderer(autoLevel: autoLevel), encoder: AudioEncoder(), remuxer: VideoRemuxer()
        )
        self.background = background ?? ContinuedProcessingScheduler()
        // Presets stay on this device for now: iCloud sync (F09.T03) is on hold (user decision, SPEC § 12).
        self.presets = presets ?? FilePresetRepository(
            root: .presetsDirectory, builtIns: Self.builtInPresetsURL.flatMap { try? BuiltInPresets.load(from: $0) } ?? []
        )
        self.idleTimer = idleTimer
        self.recordingActivity = recordingActivity
        let recordedProjects = recordedProjects ?? RecordedProjectBuilder(repository: projects, inspector: inspector)
        self.recordedProjects = recordedProjects
        self.recovery = recovery ?? TakeRecovery(root: .projectsDirectory, repository: projects, builder: recordedProjects)
        let presenter = DeliveryPresenter()
        deliveryPresenter = presenter
        destinations = [
            .photos: PhotosDestination(library: photoLibrary),
            .files: InteractiveDestination(kind: .files, presenter: presenter),
            .share: InteractiveDestination(kind: .share, presenter: presenter),
        ]
    }

    /// The bundled presets (SPEC § 12), `Resources/BuiltInPresets/BuiltInPresets.json`.
    static var builtInPresetsURL: URL? {
        Bundle.main.url(forResource: "BuiltInPresets", withExtension: "json")
    }

    /// The processor of every AI feature (SPEC § 7).
    static let aiProcessors: [AIFeature: any AIProcessing] = [
        .noiseSuppression: RNNoiseProcessor(), .clearVoice: ClearVoiceProcessor(), .voiceLeveler: VoiceLevelerProcessor(),
    ]

    func makeHomeModel() -> HomeModel {
        HomeModel(repository: projects, storage: storage, waveforms: waveforms, renders: renders)
    }

    /// Each editor gets its own playback engine and autosaver.
    func makeEditorModel(for stored: StoredProject) -> EditorModel {
        EditorModel(
            stored: stored,
            engine: AVPlaybackEngine(),
            repository: projects,
            waveforms: waveforms,
            devices: devices,
            storage: storage,
            entitlements: entitlements,
            capabilities: capabilities,
            renderer: renderer,
            janitor: janitor,
            autoLevel: autoLevel,
            presets: presets,
            clock: dateProvider,
            makeAutosaver: { [projects] onError in ProjectAutosaver(repository: projects, onError: onError) }
        )
    }

    /// The export of the editor's project as it is now (SPEC § 11).
    func makeExportModel(for editor: EditorModel) -> ExportModel {
        let project = editor.project
        let folder = projects.folder(for: project.id)
        return ExportModel(
            editor: ExportEditor(
                project: project,
                sourceVideo: project.mediaType == .video ? folder.source(fileName: project.sourceFileName) : nil,
                audio: { try await editor.audioForExport() },
                pausePlayback: { editor.pausePlayback() },
                close: { await editor.close() }
            ),
            settings: settings,
            storage: storage,
            service: exportService,
            workspace: exportWorkspace,
            destinations: destinations,
            repository: projects,
            renders: renders,
            waveforms: waveforms,
            background: background,
            fallbackTitle: String(localized: "Echo Engine export", comment: "File name of an export whose project has no title.")
        )
    }

    /// The Record tab's model with its own recording engine (SPEC § 13).
    func makeRecordModel() -> RecordModel {
        #if DEBUG
        if DebugRecordTab.usesFakes { return previewRecordModel() }
        #endif
        let engine = AVRecordingEngine(storage: storage)
        return RecordModel(
            engine: engine,
            devices: devices,
            interruptions: RecordingInterruptions(devices: devices, engine: engine),
            projects: projects,
            builder: recordedProjects,
            backingTracks: FileBackingTrackStore(root: .backingTracksDirectory),
            idleTimer: idleTimer,
            activity: recordingActivity,
            stopRelay: recordingStopRelay,
            settings: settings,
            clock: dateProvider,
            title: { DisplayFormat.recordingTitle($0) }
        )
    }

    func makeRecordingRecoveryModel() -> RecordingRecoveryModel {
        RecordingRecoveryModel(recovery: recovery, title: { DisplayFormat.recordingTitle($0) })
    }

    func makeImportModel() -> ImportModel {
        ImportModel(
            inspector: inspector, importer: importer, storage: storage, repository: projects, dateProvider: dateProvider
        )
    }
}
