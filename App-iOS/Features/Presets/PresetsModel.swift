import EchoCore
import Foundation
import Observation

/// Settings → Presets (SPEC § 12, § 14.2): the person's presets, renamed or deleted here; built-ins are shown read-only.
@MainActor
@Observable
final class PresetsModel {
    enum Failure: Equatable {
        case load, rename, delete
    }

    private(set) var builtIns: [Preset] = []
    /// By name.
    private(set) var userPresets: [Preset] = []
    private(set) var isLoaded = false
    var failure: Failure?

    @ObservationIgnored private let repository: any PresetRepository

    init(repository: any PresetRepository) {
        self.repository = repository
    }

    func load() async {
        do {
            let presets = try await repository.list()
            builtIns = presets.filter(\.isBuiltIn)
            userPresets = presets.filter { !$0.isBuiltIn }
        } catch {
            failure = .load
        }
        isLoaded = true
    }

    /// Ignores names that are empty after trimming whitespace.
    func rename(_ id: UUID, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try await repository.rename(id: id, to: name)
        } catch {
            failure = .rename
            return
        }
        await load()
    }

    /// Projects based on the preset keep their settings; they just no longer say "Based on" it.
    func delete(_ id: UUID) async {
        do {
            try await repository.delete(id: id)
        } catch {
            failure = .delete
            return
        }
        await load()
    }
}
