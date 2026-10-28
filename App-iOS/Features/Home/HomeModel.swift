import EchoCore
import Foundation
import Observation

/// Home screen state: the project list with rename and delete (SPEC § 14.1).
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
    var failure: Failure?

    private let repository: any ProjectRepository

    init(repository: any ProjectRepository) {
        self.repository = repository
    }

    func load() async {
        do {
            projects = try await repository.list()
        } catch {
            failure = .load
        }
        hasLoaded = true
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
        } catch {
            failure = .delete
        }
    }

    /// What deleting the project frees, or `nil` if it can't be measured.
    func diskUsage(of id: UUID) async -> Int64? {
        try? await repository.diskUsage(id: id)
    }
}
