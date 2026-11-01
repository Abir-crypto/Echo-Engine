@testable import EchoCore
import EchoCoreFakes
import Foundation
import Synchronization
import Testing

final class AIChainRendererTests {
    private let directory: URL
    private let source: URL
    private let processor = FakeAIProcessor()
    private let cache: FileRenderCache
    private let renderer: AIChainRenderer
    private let project = UUID()

    private let noise = AIOperation(kind: .noiseSuppression, strength: 0.8)
    private let clear = AIOperation(kind: .clearVoice, strength: 0.5)
    private let leveler = AIOperation(kind: .voiceLeveler, strength: 1)

    init() throws {
        directory = try TestMedia.makeDirectory()
        source = directory.appending(path: "working.caf")
        try Data("source".utf8).write(to: source)
        cache = FileRenderCache(root: directory.appending(path: "Renders"))
        renderer = AIChainRenderer(processor: processor, cache: cache)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func chain(_ operations: [AIOperation]) -> AIChain {
        AIChain(projectID: project, sourceRange: .full(duration: 10), operations: operations)
    }

    private func render(_ operations: [AIOperation]) async throws -> RenderedChain {
        try await renderer.render(source: source, chain: chain(operations)) { _ in }
    }

    @Test func anEmptyChainPlaysTheSource() async throws {
        let result = try await render([])
        #expect(result == RenderedChain(prefixes: [], output: source))
        #expect(await processor.processed.isEmpty)
    }

    @Test func everyPrefixIsRenderedOnTopOfThePreviousOne() async throws {
        let result = try await render([noise, clear])

        #expect(await processor.processed.map(\.kind) == [.noiseSuppression, .clearVoice])
        #expect(await processor.inputs == [source, result.prefixes[0]])
        #expect(result.output == result.prefixes[1])
        let keys = RenderKey.prefixes(projectID: project, sourceRange: .full(duration: 10), operations: [noise, clear])
        #expect(await cache.render(for: keys[1], projectID: project) == result.output)
    }

    @Test func cachedPrefixesAreReused() async throws {
        let first = try await render([noise, clear])

        let second = try await render([noise, clear, leveler])

        #expect(await processor.processed.map(\.kind) == [.noiseSuppression, .clearVoice, .voiceLeveler])
        #expect(await processor.inputs.last == first.output, "only the new step, on top of the cached one")
        #expect(Array(second.prefixes.prefix(2)) == first.prefixes)
    }

    @Test func aChangeInTheMiddleRendersFromThere() async throws {
        _ = try await render([noise, clear, leveler])
        var stronger = clear
        stronger.strength = 0.9

        _ = try await render([noise, stronger, leveler])

        let kinds = await processor.processed.map(\.kind)
        #expect(Array(kinds.suffix(2)) == [.clearVoice, .voiceLeveler])
        #expect(kinds.count == 5)
    }

    @Test func undoingAChangeFindsTheOldRendersAgain() async throws {
        let original = try await render([noise, clear])
        var stronger = clear
        stronger.strength = 0.9
        _ = try await render([noise, stronger])

        let undone = try await render([AIOperation(kind: .noiseSuppression, strength: 0.8), AIOperation(kind: .clearVoice, strength: 0.5)])

        #expect(undone == original)
        #expect(await processor.processed.count == 3)
    }

    @Test func progressCoversOnlyTheStepsToRender() async throws {
        _ = try await render([noise])
        let log = Mutex<[Double]>([])

        _ = try await renderer.render(source: source, chain: chain([noise, clear])) { value in log.withLock { $0.append(value) } }

        let values = log.withLock { $0 }
        #expect(values.first == 0)
        #expect(values.last == 1)
        #expect(values.contains(0), "the cached step adds nothing")
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    /// A render in its own task (the test class isn't `Sendable`).
    private func renderInBackground(_ operations: [AIOperation]) -> Task<RenderedChain, any Error> {
        let renderer = renderer, source = source, chain = chain(operations)
        return Task { try await renderer.render(source: source, chain: chain) { _ in } }
    }

    @Test func theLatestRequestWins() async throws {
        await processor.setDelay(.seconds(5))
        let first = renderInBackground([noise])
        while await processor.processed.isEmpty { await Task.yield() }
        await processor.setDelay(nil)

        let second = try await render([clear])

        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(second.prefixes.count == 1)
        #expect(try await cache.entries(projectID: project).count == 1, "the cancelled step stored nothing")
    }

    @Test func cancellingTheCallerStopsTheRender() async throws {
        await processor.setDelay(.seconds(5))
        let task = renderInBackground([noise, clear])
        while await processor.processed.isEmpty { await Task.yield() }

        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await processor.processed.count == 1, "it stops before the next step")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "Renders/\(project.uuidString)").path)
        #expect(leftovers.isEmpty, "no half-written renders")
    }

    @Test func processorErrorsReachTheCaller() async throws {
        await processor.setError(RenderError.cantWrite)
        await #expect(throws: RenderError.cantWrite) { try await self.render([noise]) }
    }
}

struct FirstChangedIndexTests {
    private let a = AIOperation(kind: .noiseSuppression, strength: 0.8)
    private let b = AIOperation(kind: .clearVoice, strength: 0.5)
    private let c = AIOperation(kind: .voiceLeveler, strength: 1)

    @Test func findsTheFirstDifference() {
        var weaker = b
        weaker.strength = 0.4
        #expect(AIChain.firstChangedIndex(old: [a, b, c], new: [a, b, c]) == 3)
        #expect(AIChain.firstChangedIndex(old: [a, b, c], new: [a, weaker, c]) == 1)
        #expect(AIChain.firstChangedIndex(old: [a, b], new: [a, b, c]) == 2, "appended")
        #expect(AIChain.firstChangedIndex(old: [a, b, c], new: [a, b]) == 2, "removed from the end")
        #expect(AIChain.firstChangedIndex(old: [a, b], new: [b, a]) == 0, "reordered")
        #expect(AIChain.firstChangedIndex(old: [], new: [a]) == 0)
    }

    @Test func idsDoNotCount() {
        let sameAgain = AIOperation(kind: a.kind, strength: a.strength)
        #expect(AIChain.firstChangedIndex(old: [a], new: [sameAgain]) == 1)
    }
}
