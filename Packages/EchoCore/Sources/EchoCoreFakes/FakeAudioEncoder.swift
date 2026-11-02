import EchoCore
import Foundation

/// Copies the input to the output, recording each request's settings; can fail instead.
public actor FakeAudioEncoder: AudioEncoding {
    public private(set) var encoded: [AudioExportSettings] = []
    public var error: (any Error)?

    public init() {}

    public func setError(_ error: (any Error)?) { self.error = error }

    public func encode(_ input: URL, to output: URL, settings: AudioExportSettings, progress: @Sendable (Double) -> Void) async throws {
        encoded.append(settings)
        progress(0)
        try Task.checkCancellation()
        if let error { throw error }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.copyItem(at: input, to: output)
        progress(1)
    }
}
