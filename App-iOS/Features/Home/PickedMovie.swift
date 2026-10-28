import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A video from Photos, copied to a temporary file the import deletes afterwards.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let fileManager = FileManager()
            let directory = fileManager.temporaryDirectory.appending(path: "PhotosImports/\(UUID().uuidString)")
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appending(path: received.file.lastPathComponent)
            try fileManager.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
