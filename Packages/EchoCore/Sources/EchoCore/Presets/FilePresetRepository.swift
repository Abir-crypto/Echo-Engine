import Foundation

/// User presets as `<root>/<UUID>.json` (atomic writes), plus the bundled built-ins it is given (SPEC § 12).
/// Unreadable files are skipped.
public actor FilePresetRepository: PresetRepository {
    private let root: URL
    private let builtIns: [Preset]
    private let clock: any DateProviding
    private let fileManager = FileManager()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public init(root: URL, builtIns: [Preset], clock: any DateProviding = SystemClock()) {
        self.root = root
        self.builtIns = builtIns
        self.clock = clock
    }

    public func list() throws -> [Preset] {
        let user = userIDs().compactMap { try? load(id: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return builtIns + user
    }

    public func save(_ preset: Preset) throws {
        guard !isBuiltIn(preset.id), !preset.isBuiltIn, !preset.isFromNewerVersion else { throw PresetError.readOnly }
        if let stored = try? load(id: preset.id), stored.isFromNewerVersion { throw PresetError.readOnly }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(preset).write(to: file(for: preset.id), options: .atomic)
    }

    public func rename(id: UUID, to name: String) throws {
        guard !isBuiltIn(id) else { throw PresetError.readOnly }
        var preset = try load(id: id)
        preset.name = name
        preset.updatedAt = clock.now
        try save(preset)
    }

    public func delete(id: UUID) throws {
        guard !isBuiltIn(id) else { throw PresetError.readOnly }
        let file = file(for: id)
        guard fileManager.fileExists(atPath: file.path(percentEncoded: false)) else { throw PresetError.notFound }
        try fileManager.removeItem(at: file)
    }

    private func load(id: UUID) throws -> Preset {
        let file = file(for: id)
        guard fileManager.fileExists(atPath: file.path(percentEncoded: false)) else { throw PresetError.notFound }
        return try JSONDecoder().decode(Preset.self, from: Data(contentsOf: file))
    }

    private func userIDs() -> [UUID] {
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        return names.compactMap { name in
            name.hasSuffix(".json") ? UUID(uuidString: String(name.dropLast(".json".count))) : nil
        }
    }

    private func isBuiltIn(_ id: UUID) -> Bool {
        builtIns.contains { $0.id == id }
    }

    private func file(for id: UUID) -> URL {
        root.appending(path: "\(id.uuidString).json")
    }
}
