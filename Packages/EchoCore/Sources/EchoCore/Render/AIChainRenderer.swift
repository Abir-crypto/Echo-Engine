import Foundation

/// One clip's AI stack, as rendered (SPEC § 6.3).
public struct AIChain: Equatable, Sendable {
    public let projectID: UUID
    public let sourceRange: TimeRangeCodable
    public let operations: [AIOperation]

    public init(projectID: UUID, sourceRange: TimeRangeCodable, operations: [AIOperation]) {
        self.projectID = projectID
        self.sourceRange = sourceRange
        self.operations = operations
    }

    /// The first step whose kind or strength differs; past the shorter stack's end when one extends the other
    /// (SPEC § 6.3).
    public static func firstChangedIndex(old: [AIOperation], new: [AIOperation]) -> Int {
        // SPEC's `zip(old, new).firstIndex` (a zip is a sequence, without `firstIndex`), over shared indices.
        let shared = min(old.count, new.count)
        return (0..<shared).first { old[$0].kind != new[$0].kind || old[$0].strength != new[$0].strength } ?? shared
    }
}

/// Every prefix of a chain, rendered.
public struct RenderedChain: Equatable, Sendable {
    /// One render per prefix, first operation first; empty for an empty chain.
    public let prefixes: [URL]
    /// What playback plays: the last prefix, or the source when there's no AI step.
    public let output: URL

    public init(prefixes: [URL], output: URL) {
        self.prefixes = prefixes
        self.output = output
    }
}

/// Renders an AI chain prefix by prefix (SPEC § 4.3, § 6.3).
public protocol AIChainRendering: Sendable {
    /// Makes sure every prefix of `chain` is rendered: reuses cached prefixes, renders the rest on top of the previous
    /// prefix. Progress covers only the steps that need rendering. A newer `render` call cancels this one.
    func render(source: URL, chain: AIChain, progress: @escaping @Sendable (Double) -> Void) async throws -> RenderedChain
}

public actor AIChainRenderer: AIChainRendering {
    private let processor: any AIProcessing
    private let cache: any RenderCaching
    /// The render in flight; a new request cancels it (latest change wins).
    private var current: Task<RenderedChain, any Error>?

    public init(processor: any AIProcessing, cache: any RenderCaching) {
        self.processor = processor
        self.cache = cache
    }

    public func render(source: URL, chain: AIChain, progress: @escaping @Sendable (Double) -> Void) async throws -> RenderedChain {
        current?.cancel()
        let task = Task { [processor, cache] in
            try await Self.walk(source: source, chain: chain, processor: processor, cache: cache, progress: progress)
        }
        current = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func walk(
        source: URL,
        chain: AIChain,
        processor: any AIProcessing,
        cache: any RenderCaching,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> RenderedChain {
        let keys = RenderKey.prefixes(projectID: chain.projectID, sourceRange: chain.sourceRange, operations: chain.operations)
        var cached: [URL?] = []
        for key in keys {
            cached.append(await cache.render(for: key, projectID: chain.projectID))
        }
        let toRender = Double(max(cached.count { $0 == nil }, 1))
        var rendered = 0.0
        progress(0)

        var input = source
        var prefixes: [URL] = []
        for (index, key) in keys.enumerated() {
            try Task.checkCancellation()
            if let hit = cached[index] {
                input = hit
            } else {
                let temporary = try await cache.temporaryURL(projectID: chain.projectID)
                let done = rendered
                do {
                    try await processor.process(chain.operations[index], input: input, output: temporary) { step in
                        progress((done + min(max(step, 0), 1)) / toRender)
                    }
                    input = try await cache.store(temporary, for: key, projectID: chain.projectID)
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    throw error
                }
                rendered += 1
            }
            prefixes.append(input)
        }
        progress(1)
        return RenderedChain(prefixes: prefixes, output: input)
    }
}
