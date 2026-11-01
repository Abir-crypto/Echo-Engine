import EchoCore
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
        janitor: (any RenderCacheJanitoring)? = nil
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
        let processor = AIProcessorRouter(processors: [.noiseSuppression: RNNoiseProcessor(), .clearVoice: ClearVoiceProcessor()])
        self.renderer = renderer ?? AIChainRenderer(processor: processor, cache: renders)
        self.janitor = janitor ?? RenderCacheJanitor(cache: renders, storage: storage, waveforms: waveforms)
    }

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
            makeAutosaver: { [projects] onError in ProjectAutosaver(repository: projects, onError: onError) }
        )
    }

    func makeImportModel() -> ImportModel {
        ImportModel(
            inspector: inspector, importer: importer, storage: storage, repository: projects, dateProvider: dateProvider
        )
    }
}
