import Foundation

/// Renders as `<root>/<projectID>/<key>.m4a` (SPEC § 5.1). Renders in progress are hidden `.render-<UUID>.m4a` files
/// in the same folder, so storing one is a rename.
public actor FileRenderCache: RenderCaching {
    private let root: URL
    private let fileManager = FileManager()
    private static let fileExtension = "m4a"

    public init(root: URL) {
        self.root = root
    }

    public func render(for key: RenderKey, projectID: UUID) -> URL? {
        let url = location(of: key, projectID: projectID)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    public func temporaryURL(projectID: UUID) throws -> URL {
        let folder = try makeFolder(projectID)
        return folder.appending(path: ".render-\(UUID().uuidString).\(Self.fileExtension)")
    }

    public func store(_ file: URL, for key: RenderKey, projectID: UUID) throws -> URL {
        try makeFolder(projectID)
        let destination = location(of: key, projectID: projectID)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: file)
        } else {
            try fileManager.moveItem(at: file, to: destination)
        }
        return destination
    }

    public func entries(projectID: UUID) throws -> [RenderCacheEntry] {
        let folder = folder(projectID)
        guard fileManager.fileExists(atPath: folder.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == Self.fileExtension }
            .compactMap { url in
                guard let key = RenderKey(hash: url.deletingPathExtension().lastPathComponent) else { return nil }
                let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                return RenderCacheEntry(key: key, bytes: Int64(bytes))
            }
    }

    public func remove(_ keys: Set<RenderKey>, projectID: UUID) throws {
        for key in keys {
            let url = location(of: key, projectID: projectID)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    public func removeAll(projectID: UUID) throws {
        let folder = folder(projectID)
        if fileManager.fileExists(atPath: folder.path) {
            try fileManager.removeItem(at: folder)
        }
    }

    private func folder(_ projectID: UUID) -> URL {
        root.appending(path: projectID.uuidString, directoryHint: .isDirectory)
    }

    private func location(of key: RenderKey, projectID: UUID) -> URL {
        folder(projectID).appending(path: "\(key.hash).\(Self.fileExtension)")
    }

    @discardableResult
    private func makeFolder(_ projectID: UUID) throws -> URL {
        let folder = folder(projectID)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
