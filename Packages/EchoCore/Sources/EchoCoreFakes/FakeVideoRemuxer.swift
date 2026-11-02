import EchoCore
import Foundation

/// Copies the source video to the output, recording each request; can fail instead.
public actor FakeVideoRemuxer: VideoRemuxing {
    public struct Request: Sendable {
        public let video: URL
        public let audio: URL
        public let trimRange: TimeRangeCodable
    }

    public private(set) var requests: [Request] = []
    public var error: (any Error)?

    public init() {}

    public func setError(_ error: (any Error)?) { self.error = error }

    public func remux(video: URL, audio: URL, trimRange: TimeRangeCodable, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        requests.append(Request(video: video, audio: audio, trimRange: trimRange))
        progress(0)
        try Task.checkCancellation()
        if let error { throw error }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.copyItem(at: video, to: output)
        progress(1)
    }
}
