import EchoCore
import Foundation

/// Presets in memory: the built-ins given, then saved presets by name.
public actor FakePresetRepository: PresetRepository {
    public private(set) var builtIns: [Preset]
    public private(set) var saved: [UUID: Preset] = [:]
    public var error: (any Error)?

    public init(builtIns: [Preset] = [], saved: [Preset] = []) {
        self.builtIns = builtIns
        self.saved = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
    }

    public func setError(_ error: (any Error)?) { self.error = error }

    public func list() throws -> [Preset] {
        if let error { throw error }
        return builtIns + saved.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func save(_ preset: Preset) throws {
        if let error { throw error }
        guard !preset.isBuiltIn, !builtIns.contains(where: { $0.id == preset.id }) else { throw PresetError.readOnly }
        saved[preset.id] = preset
    }

    public func rename(id: UUID, to name: String) throws {
        if let error { throw error }
        guard var preset = saved[id] else { throw builtIns.contains { $0.id == id } ? PresetError.readOnly : PresetError.notFound }
        preset.name = name
        saved[id] = preset
    }

    public func delete(id: UUID) throws {
        if let error { throw error }
        guard saved.removeValue(forKey: id) != nil else {
            throw builtIns.contains { $0.id == id } ? PresetError.readOnly : PresetError.notFound
        }
    }
}
