import EchoCore
import Foundation
import Observation

/// Runs an import: inspect → storage check → copy and extract → create the project (SPEC § 10, § 15).
@MainActor
@Observable
final class ImportModel {
    enum Phase: Equatable {
        case idle
        /// Loading from Photos or inspecting the file.
        case preparing
        /// Copying and extracting, 0...1.
        case importing(Double)
    }

    enum Failure: Equatable {
        case unsupportedFormat, noAudio, unreadable
        case needsSpace(needed: Int64, available: Int64)
        case photosUnavailable
        case failed
    }

    private(set) var phase = Phase.idle
    var failure: Failure?
    /// Set when an import finishes; Home opens it and calls `didOpenImportedProject()`.
    private(set) var importedProject: Project?

    private let inspector: any MediaInspecting
    private let importer: any MediaImporting
    private let storage: any StorageEstimating
    private let repository: any ProjectRepository
    private let dateProvider: any DateProviding
    private var task: Task<Void, Never>?

    init(
        inspector: any MediaInspecting,
        importer: any MediaImporting,
        storage: any StorageEstimating,
        repository: any ProjectRepository,
        dateProvider: any DateProviding
    ) {
        self.inspector = inspector
        self.importer = importer
        self.storage = storage
        self.repository = repository
        self.dateProvider = dateProvider
    }

    /// A file chosen with `fileImporter` (security-scoped; left in place).
    func importFile(at url: URL) {
        start { url }
    }

    /// A Photos item: `load` copies it to a temporary file, which is deleted after the import.
    func importFromPhotos(_ load: @escaping @Sendable () async throws -> URL?) {
        start(isTemporary: true) {
            do {
                guard let url = try await load() else { throw Failure.photosUnavailable }
                return url
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Failure.photosUnavailable
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func didOpenImportedProject() {
        importedProject = nil
    }

    /// Waits for the running import, for tests.
    func waitUntilFinished() async {
        await task?.value
    }

    private func start(isTemporary: Bool = false, source: @escaping @Sendable () async throws -> URL) {
        task?.cancel()
        phase = .preparing
        failure = nil
        task = Task {
            await run(source: source, isTemporary: isTemporary)
            phase = .idle
        }
    }

    private func run(source: @Sendable () async throws -> URL, isTemporary: Bool) async {
        do {
            let url = try await source()
            let isScoped = url.startAccessingSecurityScopedResource()
            defer {
                if isScoped { url.stopAccessingSecurityScopedResource() }
                if isTemporary { try? FileManager().removeItem(at: url) }
            }
            try await importProject(from: url)
        } catch is CancellationError {
            // Cancelled by the user: nothing to report.
        } catch let failure as Failure {
            self.failure = failure
        } catch let error as ImportError {
            failure = switch error {
            case .unsupportedFormat: .unsupportedFormat
            case .noAudio: .noAudio
            case .unreadable: .unreadable
            }
        } catch {
            failure = .failed
        }
    }

    private func importProject(from url: URL) async throws {
        let inspection = try await inspector.inspect(url)
        let needed = storage.bytesToImport(inspection.sourceInfo)
        let available = try storage.availableBytes()
        guard needed <= available else { throw Failure.needsSpace(needed: needed, available: available) }

        let id = UUID()
        let folder = try await repository.createFolder(for: id)
        do {
            phase = .importing(0)
            let imported = try await importer.importMedia(from: url, inspection: inspection, into: folder) { fraction in
                Task { @MainActor in self.updateProgress(fraction) }
            }
            try Task.checkCancellation()
            let project = Project(
                id: id,
                title: url.deletingPathExtension().lastPathComponent,
                mediaType: inspection.mediaType,
                origin: .imported,
                sourceFileName: imported.sourceFileName,
                sourceInfo: inspection.sourceInfo,
                createdAt: dateProvider.now
            )
            try await repository.save(project)
            importedProject = project
        } catch {
            // The partial project folder never outlives a failed or cancelled import (SPEC § 10).
            try? await repository.delete(id: id)
            throw error
        }
    }

    private func updateProgress(_ fraction: Double) {
        guard case .importing = phase else { return }
        phase = .importing(fraction)
    }
}

extension ImportModel.Failure: Error {}
