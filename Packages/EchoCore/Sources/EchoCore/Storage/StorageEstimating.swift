import Foundation

/// Bytes each stage needs and bytes available (SPEC § 15). Messages always state exact numbers.
public protocol StorageEstimating: Sendable {
    /// Copying the source and extracting `working.caf`.
    func bytesToImport(_ source: SourceInfo) -> Int64
    /// Opening the editor: room for one render twice over.
    func bytesToEdit(_ project: Project) -> Int64
    /// Exporting the trimmed range with the default output (video projects keep their video).
    func bytesToExport(_ project: Project) -> Int64
    /// Free space for important usage on the projects volume.
    func availableBytes() throws -> Int64
}

/// Whether a project can be edited and exported with the space left (SPEC § 15).
public enum ProjectReadiness: Equatable, Sendable {
    case ready
    /// Bytes still missing before the editor can open.
    case needsSpaceToEdit(Int64)
    /// Bytes still missing before an export can start.
    case needsSpaceToExport(Int64)
}

extension StorageEstimating {
    /// Editing is checked before exporting: a project that can't be edited reports that first.
    public func readiness(of project: Project, availableBytes: Int64) -> ProjectReadiness {
        let editShortfall = bytesToEdit(project) - availableBytes
        if editShortfall > 0 { return .needsSpaceToEdit(editShortfall) }
        let exportShortfall = bytesToExport(project) - availableBytes
        if exportShortfall > 0 { return .needsSpaceToExport(exportShortfall) }
        return .ready
    }
}
