import EchoCore
import Foundation

/// Renders nothing: returns made-up render URLs (`<source folder>/render-<n>.m4a` for the first `n` steps) and records
/// each chain. Can fail or wait.
public actor FakeAIChainRenderer: AIChainRendering {
    public private(set) var chains: [AIChain] = []
    public var error: (any Error)?
    public var delay: Duration?

    public init() {}

    public func setError(_ error: (any Error)?) { self.error = error }
    public func setDelay(_ delay: Duration?) { self.delay = delay }

    public func render(source: URL, chain: AIChain, progress: @escaping @Sendable (Double) -> Void) async throws -> RenderedChain {
        chains.append(chain)
        progress(0)
        if let delay { try await Task.sleep(for: delay) }
        if let error { throw error }
        progress(1)
        let prefixes = chain.operations.indices.map { Self.renderURL(source: source, steps: $0 + 1) }
        return RenderedChain(prefixes: prefixes, output: prefixes.last ?? source)
    }

    /// Where this fake says the render of the first `steps` operations is.
    public static func renderURL(source: URL, steps: Int) -> URL {
        source.deletingLastPathComponent().appending(path: "render-\(steps).m4a")
    }
}
