import EchoCore
import Foundation

/// Answers `key` for every file and counts the calls.
public actor FakeKeyDetector: KeyDetecting {
    public private(set) var detections: [URL] = []
    private let key: MusicalKey?

    public init(key: MusicalKey? = nil) {
        self.key = key
    }

    public func detectKey(of url: URL) async throws -> MusicalKey? {
        detections.append(url)
        return key
    }
}
