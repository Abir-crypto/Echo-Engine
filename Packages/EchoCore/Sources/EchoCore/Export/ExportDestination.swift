import Foundation

/// Where an export goes (SPEC § 11.1 "Save to").
public enum DestinationKind: String, Codable, CaseIterable, Sendable {
    case photos, files, share
}

/// How a delivery ended. Post-export actions run only after `.delivered` (SPEC § 11.2 step 6).
public enum DeliveryOutcome: Equatable, Sendable {
    case delivered
    /// The person closed the picker or share sheet without saving.
    case cancelled
}

/// Delivers a finished export file (SPEC § 4.3, § 11.2 step 5). Throws `ExportError` when delivery fails.
public protocol ExportDestination: Sendable {
    var kind: DestinationKind { get }
    func deliver(_ file: URL) async throws -> DeliveryOutcome
}

/// Adding videos to the photo library (wraps PhotoKit's shared library, SPEC § 4.1).
public protocol PhotoLibraryAdding: Sendable {
    /// Asks for add-only access when not decided yet; whether adding is allowed.
    func requestAddAccess() async -> Bool
    /// Adds the video as a new asset, moving the file into the library (`shouldMoveFile`) under its file name.
    func addVideo(movingFileAt url: URL) async throws
}

/// Photos (SPEC § 11.2 step 5): `PHAssetCreationRequest` with `shouldMoveFile`, so the video isn't copied.
public struct PhotosDestination: ExportDestination {
    private let library: any PhotoLibraryAdding

    public init(library: any PhotoLibraryAdding) {
        self.library = library
    }

    public var kind: DestinationKind { .photos }

    public func deliver(_ file: URL) async throws -> DeliveryOutcome {
        guard await library.requestAddAccess() else { throw ExportError.photoLibraryDenied }
        do {
            try await library.addVideo(movingFileAt: file)
        } catch {
            throw ExportError.photoLibraryFailed
        }
        return .delivered
    }
}
