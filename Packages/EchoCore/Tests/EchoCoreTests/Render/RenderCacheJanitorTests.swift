@testable import EchoCore
import EchoCoreFakes
import Foundation
import Testing

final class RenderCacheJanitorTests {
    private let root: URL
    private let cache: FileRenderCache
    private let project = UUID()
    private let range = TimeRangeCodable.full(duration: 60)

    private let a = AIOperation(kind: .noiseSuppression, strength: 1)
    private let b = AIOperation(kind: .clearVoice, strength: 0.5)
    private let c = AIOperation(kind: .clearVoice, strength: 0.8)
    private let d = AIOperation(kind: .voiceLeveler, strength: 1)

    init() throws {
        root = try TestMedia.makeDirectory()
        cache = FileRenderCache(root: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func state(_ stack: [AIOperation]) -> EditState {
        EditState(aiStack: stack, manual: ManualSettings(), trimRange: range, outputLoudness: nil)
    }

    private func key(_ stack: [AIOperation]) -> RenderKey {
        RenderKey(projectID: project, sourceRange: range, operations: stack)
    }

    /// Caches a render of `bytes` for every prefix of `stack`.
    private func cacheRenders(of stack: [AIOperation], bytes: Int = 100) async throws {
        for prefix in RenderKey.prefixes(projectID: project, sourceRange: range, operations: stack) {
            let temporary = try await cache.temporaryURL(projectID: project)
            try Data(count: bytes).write(to: temporary)
            _ = try await cache.store(temporary, for: prefix, projectID: project)
        }
    }

    private func cachedKeys() async throws -> Set<RenderKey> {
        Set(try await cache.entries(projectID: project).map(\.key))
    }

    private func janitor(available: Int64 = .max, failsToMeasure: Bool = false) -> RenderCacheJanitor {
        var storage = FakeStorageEstimator(available: available)
        storage.failsToMeasure = failsToMeasure
        return RenderCacheJanitor(cache: cache, storage: storage)
    }

    @Test func keepsTheCurrentPrefixesAndEveryHistoryStateAndDeletesTheRest() async throws {
        try await cacheRenders(of: [a, b])
        try await cacheRenders(of: [a, c])
        try await cacheRenders(of: [d])

        try await janitor().sweep(projectID: project, sourceRange: range, current: state([a, c]), history: [state([a, b])])

        #expect(try await cachedKeys() == [key([a]), key([a, b]), key([a, c])])
    }

    @Test func overBudgetTheOldestHistoryStatesGoFirst() async throws {
        try await cacheRenders(of: [b])        // oldest
        try await cacheRenders(of: [c])
        try await cacheRenders(of: [a, d])     // current: 200 bytes
        // 10 % of 3,000 bytes free = a 300-byte budget for 400 bytes of reachable renders.
        try await janitor(available: 3_000).sweep(
            projectID: project, sourceRange: range, current: state([a, d]), history: [state([b]), state([c])]
        )

        #expect(try await cachedKeys() == [key([c]), key([a]), key([a, d])])
    }

    @Test func evictionKeepsRendersANewerStateShares() async throws {
        try await cacheRenders(of: [a, b])     // oldest: [a] and [a, b]
        try await cacheRenders(of: [a, c])     // newer history state, also needs [a]
        try await cacheRenders(of: [d])        // current

        try await janitor(available: 3_000).sweep(
            projectID: project, sourceRange: range, current: state([d]), history: [state([a, b]), state([a, c])]
        )

        #expect(try await cachedKeys() == [key([a]), key([a, c]), key([d])])
    }

    @Test func theCurrentStateIsNeverEvicted() async throws {
        try await cacheRenders(of: [a, b, c], bytes: 1_000)
        try await cacheRenders(of: [d], bytes: 1_000)

        try await janitor(available: 100).sweep(projectID: project, sourceRange: range, current: state([a, b, c]), history: [state([d])])

        #expect(try await cachedKeys() == [key([a]), key([a, b]), key([a, b, c])])
    }

    @Test func theBudgetIsTwoGigabytesWhenFreeSpaceIsUnknown() async throws {
        try await cacheRenders(of: [b])
        try await cacheRenders(of: [a])

        try await janitor(failsToMeasure: true).sweep(projectID: project, sourceRange: range, current: state([a]), history: [state([b])])

        #expect(try await cachedKeys() == [key([a]), key([b])])
    }

    @Test func closingKeepsOnlyTheCurrentPrefixes() async throws {
        try await cacheRenders(of: [a, b])
        try await cacheRenders(of: [c])

        try await janitor().prune(projectID: project, sourceRange: range, current: state([a, b]))

        #expect(try await cachedKeys() == [key([a]), key([a, b])])
    }
}
