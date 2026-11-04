import Foundation

/// A take the app was killed during (SPEC § 13.3): its project folder has a session marker but no manifest.
public struct UnfinishedTake: Identifiable, Equatable, Sendable {
    /// The project folder the take was recorded into.
    public let id: UUID
    public let session: TakeSession
    /// Seconds of audio saved.
    public let duration: Double

    public init(id: UUID, session: TakeSession, duration: Double) {
        self.id = id
        self.session = session
        self.duration = duration
    }
}

/// Finds unfinished takes at launch and recovers or deletes them (SPEC § 13.3).
public protocol RecordingRecovering: Sendable {
    /// Unfinished takes, oldest first. Tidies up on the way: a marker left beside a saved project is removed, and a
    /// take with no audio at all is deleted.
    func unfinishedTakes() async -> [UnfinishedTake]
    /// Makes a recorded project of the take, like Stop, editing the processed mixdown.
    func recover(_ take: UnfinishedTake, title: String) async throws -> Project
    func delete(_ take: UnfinishedTake) async throws
}

public struct TakeRecovery: RecordingRecovering {
    private let root: URL
    private let repository: any ProjectRepository
    private let builder: any RecordedProjectBuilding

    /// `root` holds the project folders (`URL.projectsDirectory`).
    public init(root: URL, repository: any ProjectRepository, builder: any RecordedProjectBuilding) {
        self.root = root
        self.repository = repository
        self.builder = builder
    }

    public func unfinishedTakes() async -> [UnfinishedTake] {
        guard let names = try? FileManager().contentsOfDirectory(atPath: root.path(percentEncoded: false)) else { return [] }
        var takes: [UnfinishedTake] = []
        for id in names.compactMap(UUID.init(uuidString:)) {
            let takeFolder = repository.folder(for: id).takeFolder
            guard let session = try? TakeSession.read(from: takeFolder) else { continue }
            if (try? await repository.load(id: id)) != nil {
                // The project was saved; only removing the marker was left.
                try? TakeSession.remove(from: takeFolder)
                continue
            }
            let frames = (try? CAFWriter.frameCount(at: takeFolder.processed)) ?? 0
            guard frames > 0 else {
                try? await repository.delete(id: id)
                continue
            }
            takes.append(UnfinishedTake(id: id, session: session, duration: Double(frames) / RecordingConfiguration.sampleRate))
        }
        return takes.sorted { $0.session.startedAt < $1.session.startedAt }
    }

    public func recover(_ take: UnfinishedTake, title: String) async throws -> Project {
        try await builder.buildProject(id: take.id, title: title, session: take.session, editingSource: .processed)
    }

    public func delete(_ take: UnfinishedTake) async throws {
        try await repository.delete(id: take.id)
    }
}
