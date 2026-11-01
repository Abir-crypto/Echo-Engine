@testable import EchoCore
import Foundation
import Testing

struct RenderKeyTests {
    private let project = UUID(uuidString: "6F1C2B3A-0000-4000-8000-000000000001")!
    private let range = TimeRangeCodable(start: 0, duration: 198.5)
    private let noise = AIOperation(kind: .noiseSuppression, strength: 0.8)
    private let clear = AIOperation(kind: .clearVoice, strength: 0.5)

    @Test func theSameChainHasTheSameKeyWhateverTheOperationIDs() {
        let again = [AIOperation(kind: .noiseSuppression, strength: 0.8), AIOperation(kind: .clearVoice, strength: 0.5)]
        #expect(RenderKey(projectID: project, sourceRange: range, operations: [noise, clear])
            == RenderKey(projectID: project, sourceRange: range, operations: again))
    }

    @Test func everyPartOfTheChainChangesTheKey() {
        let key = RenderKey(projectID: project, sourceRange: range, operations: [noise, clear])
        var stronger = clear
        stronger.strength = 0.6
        let variants = [
            RenderKey(projectID: UUID(), sourceRange: range, operations: [noise, clear]),
            RenderKey(projectID: project, sourceRange: TimeRangeCodable(start: 0, duration: 198), operations: [noise, clear]),
            RenderKey(projectID: project, sourceRange: range, operations: [clear, noise]),
            RenderKey(projectID: project, sourceRange: range, operations: [noise, stronger]),
            RenderKey(projectID: project, sourceRange: range, operations: [noise]),
        ]
        #expect(Set(variants + [key]).count == 6)
    }

    @Test func prefixesCoverEveryStep() {
        let keys = RenderKey.prefixes(projectID: project, sourceRange: range, operations: [noise, clear])
        #expect(keys == [
            RenderKey(projectID: project, sourceRange: range, operations: [noise]),
            RenderKey(projectID: project, sourceRange: range, operations: [noise, clear]),
        ])
    }

    @Test func keysAreHexAndRoundTripThroughFileNames() {
        let key = RenderKey(projectID: project, sourceRange: range, operations: [noise])
        #expect(key.hash.count == 64)
        #expect(RenderKey(hash: key.hash) == key)
        #expect(RenderKey(hash: "not-a-key") == nil)
        #expect(RenderKey(hash: key.hash.uppercased()) == nil)
    }

    @Test func theKeyIsTheHashOfAFixedLocaleIndependentText() {
        // SHA-256 of "6f1c2b3a-0000-4000-8000-000000000001|0.000000,198.500000|noiseSuppression:0.8000"
        // ("." decimals, fixed digits), computed outside the app. Keys must never change between versions or devices.
        #expect(RenderKey(projectID: project, sourceRange: range, operations: [noise]).hash
            == "9a23462d66e5a7caaad419c3c0b37c8d6a8f4773569e96f88f4f9111de60f270")
    }
}

final class FileRenderCacheTests {
    private let root: URL
    private let cache: FileRenderCache
    private let project = UUID()
    private let key = RenderKey(projectID: UUID(), sourceRange: .full(duration: 10), operations: [AIOperation(kind: .clearVoice, strength: 1)])

    init() throws {
        root = try TestMedia.makeDirectory()
        cache = FileRenderCache(root: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func finishedRender(_ bytes: Int = 1_000) async throws -> URL {
        let url = try await cache.temporaryURL(projectID: project)
        try Data(count: bytes).write(to: url)
        return url
    }

    @Test func aStoredRenderIsFoundUnderItsKey() async throws {
        #expect(await cache.render(for: key, projectID: project) == nil)

        let stored = try await cache.store(try await finishedRender(), for: key, projectID: project)

        #expect(await cache.render(for: key, projectID: project) == stored)
        #expect(stored.path.hasSuffix("\(project.uuidString)/\(key.hash).m4a"))
        #expect(await cache.render(for: key, projectID: UUID()) == nil, "per project")
    }

    @Test func storingAgainReplacesTheRender() async throws {
        _ = try await cache.store(try await finishedRender(1_000), for: key, projectID: project)
        _ = try await cache.store(try await finishedRender(2_000), for: key, projectID: project)
        #expect(try await cache.entries(projectID: project) == [RenderCacheEntry(key: key, bytes: 2_000)])
    }

    @Test func entriesListRendersButNotOnesInProgress() async throws {
        _ = try await cache.store(try await finishedRender(1_500), for: key, projectID: project)
        _ = try await finishedRender(9_999)

        #expect(try await cache.entries(projectID: project) == [RenderCacheEntry(key: key, bytes: 1_500)])
        #expect(try await cache.entries(projectID: UUID()).isEmpty)
    }

    @Test func removingKeysAndProjects() async throws {
        let other = RenderKey(projectID: project, sourceRange: .full(duration: 10), operations: [])
        _ = try await cache.store(try await finishedRender(), for: key, projectID: project)
        _ = try await cache.store(try await finishedRender(), for: other, projectID: project)

        try await cache.remove([key], projectID: project)
        #expect(try await cache.entries(projectID: project).map(\.key) == [other])

        try await cache.removeAll(projectID: project)
        #expect(try await cache.entries(projectID: project).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: project.uuidString).path))
    }
}
