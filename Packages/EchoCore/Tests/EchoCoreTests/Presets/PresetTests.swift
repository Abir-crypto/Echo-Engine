import EchoCore
import EchoCoreFakes
import Foundation
import Testing

private let created = Date(timeIntervalSince1970: 1_800_000_000)

private func userPreset(_ name: String, schemaVersion: Int = Preset.currentSchemaVersion) -> Preset {
    var manual = ManualSettings()
    manual.inputGainDB = 3
    var preset = Preset(
        name: name,
        aiStack: [AIOperation(kind: .noiseSuppression, strength: 0.6)],
        manual: manual,
        outputLoudness: .custom(lufs: -18),
        createdAt: created
    )
    preset.schemaVersion = schemaVersion
    return preset
}

private let builtIn = Preset(
    id: BuiltInPresetID.podcastVoice, name: "Podcast Voice", aiStack: [], manual: ManualSettings(), outputLoudness: .podcast,
    isBuiltIn: true, createdAt: created
)

struct PresetModelTests {
    @Test func aPresetRoundTripsThroughJSON() throws {
        let preset = userPreset("Studio")
        let decoded = try JSONDecoder().decode(Preset.self, from: JSONEncoder().encode(preset))
        #expect(decoded == preset)
        #expect(!decoded.isBuiltIn)
        #expect(decoded.updatedAt == created)
    }

    @Test func builtInsLoadFromBundledJSONAsReadOnly() throws {
        var listed = builtIn
        listed.isBuiltIn = false
        let url = FileManager.default.temporaryDirectory.appending(path: "builtins-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode([listed]).write(to: url)

        let loaded = try BuiltInPresets.load(from: url)

        #expect(loaded.map(\.id) == [BuiltInPresetID.podcastVoice])
        #expect(loaded.allSatisfy { $0.isBuiltIn }, "bundled presets are built-in whatever the file says")
    }
}

final class FilePresetRepositoryTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "Presets-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let clock = FakeClock(now: Date(timeIntervalSince1970: 1_900_000_000))

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func repository() -> FilePresetRepository {
        FilePresetRepository(root: root, builtIns: [builtIn], clock: clock)
    }

    @Test func theBuiltInsComeFirst() async throws {
        #expect(try await repository().list() == [builtIn])
    }

    @Test func savedPresetsAreKeptAndListedByName() async throws {
        let store = repository()
        let studio = userPreset("Studio"), alpha = userPreset("alpha")
        try await store.save(studio)
        try await store.save(alpha)

        let relaunched = repository()
        #expect(try await relaunched.list() == [builtIn, alpha, studio])
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "\(studio.id.uuidString).json").path(percentEncoded: false)))
    }

    @Test func savingAgainReplacesThePreset() async throws {
        let store = repository()
        var preset = userPreset("Studio")
        try await store.save(preset)
        preset.manual.inputGainDB = -4
        try await store.save(preset)

        #expect(try await store.list().last?.manual.inputGainDB == -4)
        #expect(try await store.list().count == 2)
    }

    @Test func renamingStampsTheTime() async throws {
        let store = repository()
        let preset = userPreset("Studio")
        try await store.save(preset)

        try await store.rename(id: preset.id, to: "Booth")

        let renamed = try #require(try await store.list().last)
        #expect(renamed.name == "Booth")
        #expect(renamed.updatedAt == clock.now)
        #expect(renamed.createdAt == created)
    }

    @Test func deletingRemovesTheFile() async throws {
        let store = repository()
        let preset = userPreset("Studio")
        try await store.save(preset)

        try await store.delete(id: preset.id)

        #expect(try await store.list() == [builtIn])
        await #expect(throws: PresetError.notFound) { try await store.delete(id: preset.id) }
    }

    @Test func builtInsCantBeChanged() async throws {
        let store = repository()
        await #expect(throws: PresetError.readOnly) { try await store.save(builtIn) }
        await #expect(throws: PresetError.readOnly) { try await store.rename(id: builtIn.id, to: "Mine") }
        await #expect(throws: PresetError.readOnly) { try await store.delete(id: builtIn.id) }
    }

    @Test func presetsFromANewerVersionAreListedButNeverOverwritten() async throws {
        let newer = userPreset("From the future", schemaVersion: Preset.currentSchemaVersion + 1)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(newer).write(to: root.appending(path: "\(newer.id.uuidString).json"))
        let store = repository()

        #expect(try await store.list().contains(newer))
        await #expect(throws: PresetError.readOnly) { try await store.rename(id: newer.id, to: "Now") }
        await #expect(throws: PresetError.readOnly) { try await store.save(newer) }
    }

    @Test func unreadableFilesAreSkipped() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: root.appending(path: "\(UUID().uuidString).json"))
        try Data("ignored".utf8).write(to: root.appending(path: ".DS_Store"))

        #expect(try await repository().list() == [builtIn])
    }
}
