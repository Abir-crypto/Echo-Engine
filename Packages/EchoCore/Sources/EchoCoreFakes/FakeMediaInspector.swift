import EchoCore
import Foundation

/// Returns `result` for every URL, or throws `error` when set.
public struct FakeMediaInspector: MediaInspecting {
    public var result: MediaInspection
    public var error: ImportError?

    public init(result: MediaInspection, error: ImportError? = nil) {
        self.result = result
        self.error = error
    }

    public func inspect(_ url: URL) async throws -> MediaInspection {
        if let error { throw error }
        return result
    }
}
