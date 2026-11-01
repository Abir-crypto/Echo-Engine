import EchoCore
import Foundation

/// Copies the input to the output, recording each operation; can fail or wait for cancellation.
public actor FakeAIProcessor: AIProcessing {
    public private(set) var processed: [AIOperation] = []
    public var error: (any Error)?
    /// When set, `process` waits this long (cancellable) before copying.
    public var delay: Duration?

    public init() {}

    public func setError(_ error: (any Error)?) { self.error = error }
    public func setDelay(_ delay: Duration?) { self.delay = delay }

    public func process(_ op: AIOperation, input: URL, output: URL, progress: @Sendable (Double) -> Void) async throws {
        processed.append(op)
        progress(0)
        if let delay { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        if let error { throw error }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.copyItem(at: input, to: output)
        progress(1)
    }
}
