import EchoCore
import Foundation
import Observation
import UIKit

/// Home screen state: the project list with thumbnails, storage readiness, rename and delete (SPEC § 14.1, § 15).
@MainActor
@Observable
final class HomeModel {
    enum Failure: Equatable {
        case load, rename, delete
        /// The project was made by a newer app version.
        case readOnly
    }

    private(set) var projects: [StoredProject] = []
    private(set) var hasLoaded = false
    /// Per project; missing when free space couldn't be read.
    private(set) var readiness: [UUID: ProjectReadiness] = [:]
    /// Loaded per card with `loadThumbnail(for:)`; thumbnails never change after import.
    private(set) var thumbnails: [UUID: ProjectThumbnail] = [:]
    var failure: Failure?

    private let repository: any ProjectRepository
    private let storage: any StorageEstimating

    init(repository: any ProjectRepository, storage: any StorageEstimating) {
        self.repository = repository
        self.storage = storage
    }

    func load() async {
        do {
            projects = try await repository.list()
        } catch {
            failure = .load
        }
        if let available = try? storage.availableBytes() {
            readiness = Dictionary(uniqueKeysWithValues: projects.map {
                ($0.project.id, storage.readiness(of: $0.project, availableBytes: available))
            })
        }
        hasLoaded = true
    }

    /// Video projects show their frame; projects without one fall back to their waveform overview.
    func loadThumbnail(for project: Project) async {
        guard thumbnails[project.id] == nil else { return }
        if project.mediaType == .video, let data = await repository.thumbnail(id: project.id), let image = UIImage(data: data) {
            thumbnails[project.id] = .frame(image)
        } else if let levels = await repository.waveformOverview(id: project.id) {
            thumbnails[project.id] = .levels(levels)
        }
    }

    /// Ignores titles that are empty after trimming whitespace.
    func rename(_ id: UUID, to title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            try await repository.rename(id: id, to: title)
            await load()
        } catch ProjectRepositoryError.readOnly {
            failure = .readOnly
        } catch {
            failure = .rename
        }
    }

    func delete(_ id: UUID) async {
        do {
            try await repository.delete(id: id)
            projects.removeAll { $0.project.id == id }
            thumbnails[id] = nil
            readiness[id] = nil
        } catch {
            failure = .delete
        }
    }

    /// What deleting the project frees, or `nil` if it can't be measured.
    func diskUsage(of id: UUID) async -> Int64? {
        try? await repository.diskUsage(id: id)
    }
}
