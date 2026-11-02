import Foundation

/// Temporary files of exports (SPEC § 11.2): one folder per export, removed when the export ends. Leftovers of
/// exports the app never finished (it was killed) are removed at launch.
public struct ExportWorkspace: Sendable {
    /// File names stay well under the file system's 255 bytes.
    public static let maximumFileNameBytes = 200

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// A new, empty folder for one export.
    public func makeFolder() throws -> URL {
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager().createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    public func remove(_ folder: URL) {
        try? FileManager().removeItem(at: folder)
    }

    /// Removes every export folder.
    public func removeAll() {
        let files = FileManager()
        for item in (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? files.removeItem(at: item)
        }
    }

    /// The exported file's name: the project title (what Files and the share sheet show), made safe for a file name.
    /// `fallback` (localized by the app) names files of untitled projects.
    public static func fileName(title: String, fallback: String, fileExtension: String) -> String {
        let suffix = "." + fileExtension
        var base = String(title.map { character -> Character in
            if character == "/" || character == ":" { return "-" }
            return character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } ? " " : character
        })
        base = base.trimmingCharacters(in: .whitespaces)
        base = String(base.drop { $0 == "." }).trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = fallback }
        while base.utf8.count + suffix.utf8.count > maximumFileNameBytes {
            base.removeLast()
        }
        return base + suffix
    }
}

extension URL {
    /// Exports in progress: `tmp/Exports/<export>/`.
    public static var exportTemporaryDirectory: URL {
        FileManager().temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
    }
}
