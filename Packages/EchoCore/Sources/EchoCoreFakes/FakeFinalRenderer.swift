import EchoCore
import Foundation

/// Copies the request's audio to the output, recording each request; can fail instead.
public actor FakeFinalRenderer: FinalRendering {
    public private(set) var requests: [FinalRenderRequest] = []
    public var error: (any Error)?

    public init() {}

    public func setError(_ error: (any Error)?) { self.error = error }

    public func render(_ request: FinalRenderRequest, to output: URL, progress: @Sendable (Double) -> Void) async throws {
        requests.append(request)
        progress(0)
        try Task.checkCancellation()
        if let error { throw error }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.copyItem(at: request.audio, to: output)
        progress(1)
    }
}
