import EchoCore
import Foundation

/// Renders nothing: returns the source as the output and records each chain.
public actor FakeAIChainRenderer: AIChainRendering {
    public private(set) var chains: [AIChain] = []
    public var error: (any Error)?

    public init() {}

    public func setError(_ error: (any Error)?) { self.error = error }

    public func render(source: URL, chain: AIChain, progress: @escaping @Sendable (Double) -> Void) async throws -> RenderedChain {
        chains.append(chain)
        if let error { throw error }
        progress(1)
        return RenderedChain(prefixes: chain.operations.map { _ in source }, output: source)
    }
}
