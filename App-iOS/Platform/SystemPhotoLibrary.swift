import EchoCore
import Foundation
import Photos

/// PhotoKit's shared library (SPEC § 4.1, § 11.2 step 5): add-only access; exported videos are moved in, not copied.
struct SystemPhotoLibrary: PhotoLibraryAdding {
    func requestAddAccess() async -> Bool {
        switch await PHPhotoLibrary.requestAuthorization(for: .addOnly) {
        case .authorized, .limited: true
        default: false
        }
    }

    func addVideo(movingFileAt url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            options.originalFilename = url.lastPathComponent
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: options)
        }
    }
}
