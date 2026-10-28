import EchoCore

/// Fixed byte counts for every stage.
public struct FakeStorageEstimator: StorageEstimating {
    public var importBytes: Int64
    public var editBytes: Int64
    public var exportBytes: Int64
    public var available: Int64

    public init(importBytes: Int64 = 0, editBytes: Int64 = 0, exportBytes: Int64 = 0, available: Int64 = .max) {
        self.importBytes = importBytes
        self.editBytes = editBytes
        self.exportBytes = exportBytes
        self.available = available
    }

    public func bytesToImport(_ source: SourceInfo) -> Int64 { importBytes }
    public func bytesToEdit(_ project: Project) -> Int64 { editBytes }
    public func bytesToExport(_ project: Project) -> Int64 { exportBytes }
    public func availableBytes() -> Int64 { available }
}
