import EchoCore
import Foundation

/// Keeps renders in a temporary folder, by project and key; records removals.
public actor FakeRenderCache: RenderCaching {
    private let folder: URL
    private var renders: [UUID: [RenderKey: URL]] = [:]
    public private(set) var removedAllProjectIDs: [UUID] = []

    public init() {
        folder = FileManager.default.temporaryDirectory.appending(path: "FakeRenderCache-\(UUID().uuidString)")
    }

    public func render(for key: RenderKey, projectID: UUID) -> URL? {
        renders[projectID]?[key]
    }

    public func temporaryURL(projectID: UUID) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "tmp-\(UUID().uuidString).m4a")
    }

    public func store(_ file: URL, for key: RenderKey, projectID: UUID) throws -> URL {
        let destination = folder.appending(path: "\(projectID.uuidString)-\(key.hash).m4a")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
        renders[projectID, default: [:]][key] = destination
        return destination
    }

    public func entries(projectID: UUID) -> [RenderCacheEntry] {
        (renders[projectID] ?? [:]).map { key, url in
            RenderCacheEntry(key: key, bytes: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
    }

    public func remove(_ keys: Set<RenderKey>, projectID: UUID) {
        for key in keys {
            if let url = renders[projectID]?.removeValue(forKey: key) { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// What `totalBytes` reports.
    public var bytes: Int64 = 0
    public private(set) var removedEverythingCount = 0

    public func totalBytes() -> Int64 { bytes }

    public func setBytes(_ bytes: Int64) {
        self.bytes = bytes
    }

    public func removeEverything() {
        renders.removeAll()
        bytes = 0
        removedEverythingCount += 1
    }

    public func removeAll(projectID: UUID) {
        removedAllProjectIDs.append(projectID)
        for url in (renders.removeValue(forKey: projectID) ?? [:]).values { try? FileManager.default.removeItem(at: url) }
    }
}
