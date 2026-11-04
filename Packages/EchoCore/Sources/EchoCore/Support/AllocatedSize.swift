import Foundation

extension FileManager {
    /// Bytes the file, or the files under the folder, at `url` take on disk; 0 when it doesn't exist.
    func allocatedSize(of url: URL) throws -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        var isDirectory: ObjCBool = false
        guard fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return Int64(try url.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize ?? 0)
        }
        guard let files = enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true { total += Int64(values.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// Removes everything inside `url`, keeping the folder.
    func removeContents(of url: URL) throws {
        guard fileExists(atPath: url.path(percentEncoded: false)) else { return }
        for item in try contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            try removeItem(at: item)
        }
    }
}
