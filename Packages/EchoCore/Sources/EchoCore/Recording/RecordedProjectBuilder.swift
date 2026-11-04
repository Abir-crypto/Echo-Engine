import Foundation

/// Turns a take into a recorded project (SPEC § 13.3): on Stop, and when recovering a take the app was killed during.
public protocol RecordedProjectBuilding: Sendable {
    /// Finishes the take files in project `id`'s `takes/` folder, clones the editing source as `working.caf` (no extra
    /// space on APFS) — or, for `.mix`, mixes the processed take with the session's backing track into it (SPEC § 13.6) —
    /// saves the waveform overview and the manifest, then removes the session marker. `title` is the localized default
    /// title (SPEC § 5.4). Throws `.emptyTake` when the take holds no audio, `.cantCreateProject` when a file can't be
    /// made.
    func buildProject(id: UUID, title: String, session: TakeSession, editingSource: RecordingMetadata.Take) async throws -> Project
    /// A recorded project edits the raw or the processed take (`source`) from now on (SPEC § 13.3, user decision):
    /// `working.caf` and the waveform overview are made from it again, and the project comes back with its new source
    /// (to save). Renders made from the other take no longer apply; the caller clears them. Mix projects can't switch.
    func switchEditingSource(of project: Project, to source: RecordingMetadata.Take) async throws -> Project
}

public struct RecordedProjectBuilder: RecordedProjectBuilding {
    private let repository: any ProjectRepository
    private let inspector: any MediaInspecting

    public init(repository: any ProjectRepository, inspector: any MediaInspecting) {
        self.repository = repository
        self.inspector = inspector
    }

    public func buildProject(id: UUID, title: String, session: TakeSession, editingSource: RecordingMetadata.Take) async throws -> Project {
        let folder = repository.folder(for: id)
        let takes = folder.takeFolder
        let files = FileManager()
        let source = editingSource == .raw ? takes.raw : takes.processed
        let backing = editingSource == .mix ? session.backingTrack : nil
        if editingSource == .mix, backing == nil { throw RecordingError.cantCreateProject }
        let frames: Int64
        do {
            // After a kill the files' data sizes are still unknown; set them so every reader agrees on the length.
            let takeFiles = try files.contentsOfDirectory(at: takes.url, includingPropertiesForKeys: nil).filter { $0.pathExtension == "caf" }
            for file in takeFiles where file != source {
                _ = try? CAFWriter.finish(at: file)
            }
            frames = try CAFWriter.finish(at: source)
        } catch {
            throw RecordingError.cantCreateProject
        }
        guard frames > 0 else { throw RecordingError.emptyTake }
        let project: Project
        do {
            if files.fileExists(atPath: folder.working.path(percentEncoded: false)) {
                try files.removeItem(at: folder.working)
            }
            if let backing {
                try TakeMixer.mix(
                    vocal: source, backing: takes.url.appending(path: backing.fileName), startSeconds: backing.startSeconds,
                    latencySeconds: backing.latencySeconds, volume: backing.volume, to: folder.working
                )
            } else {
                try files.copyItem(at: source, to: folder.working)
            }
            let inspection = try await inspector.inspect(folder.working)
            try JSONEncoder().encode(try WaveformOverview.levels(of: folder.working)).write(to: folder.waveformOverview, options: .atomic)
            project = Project(
                id: id,
                title: title,
                mediaType: .audio,
                origin: .recorded,
                sourceFileName: "takes/\(source.lastPathComponent)",
                sourceInfo: inspection.sourceInfo,
                recording: RecordingMetadata(
                    channelNames: session.channelNames, editingSource: editingSource, markers: session.markers,
                    parameterChanges: session.parameterChanges, backingTrack: session.backingTrack
                ),
                createdAt: session.startedAt
            )
            try await repository.save(project)
        } catch {
            throw RecordingError.cantCreateProject
        }
        try? TakeSession.remove(from: takes)
        return project
    }

    public func switchEditingSource(of project: Project, to source: RecordingMetadata.Take) async throws -> Project {
        guard source == .raw || source == .processed, let recording = project.recording,
              recording.editingSource == .raw || recording.editingSource == .processed else {
            throw RecordingError.cantCreateProject
        }
        let folder = repository.folder(for: project.id)
        let take = source == .raw ? folder.takeFolder.raw : folder.takeFolder.processed
        let files = FileManager()
        do {
            // Copied aside first, so a failure leaves the current audio in place.
            let replacement = folder.url.appending(path: ".working-\(UUID().uuidString).caf")
            try files.copyItem(at: take, to: replacement)
            _ = try files.replaceItemAt(folder.working, withItemAt: replacement)
            try JSONEncoder().encode(try WaveformOverview.levels(of: folder.working)).write(to: folder.waveformOverview, options: .atomic)
        } catch {
            throw RecordingError.cantCreateProject
        }
        var switched = project
        switched.recording?.editingSource = source
        switched.sourceFileName = "takes/\(take.lastPathComponent)"
        return switched
    }
}
