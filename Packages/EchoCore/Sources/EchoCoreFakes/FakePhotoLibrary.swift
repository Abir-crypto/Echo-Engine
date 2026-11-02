import EchoCore
import Foundation

/// Records added videos instead of touching the photo library; can deny access or fail.
public actor FakePhotoLibrary: PhotoLibraryAdding {
    public private(set) var added: [URL] = []
    public var grantsAccess: Bool
    public var failure: (any Error)?

    public init(grantsAccess: Bool = true) {
        self.grantsAccess = grantsAccess
    }

    public func setFailure(_ failure: (any Error)?) { self.failure = failure }

    public func requestAddAccess() async -> Bool { grantsAccess }

    public func addVideo(movingFileAt url: URL) async throws {
        if let failure { throw failure }
        added.append(url)
    }
}
