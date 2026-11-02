import EchoCore
import Foundation

/// Writes small placeholder files named like real exports and records each job; can wait or fail.
public actor FakeExportService: ExportService {
    public private(set) var jobs: [ExportJob] = []
    public var error: (any Error)?
    /// When set, `export` waits this long (cancellable) first.
    public var delay: Duration?

    public init() {}

    public func setError(_ error: (any Error)?) { self.error = error }
    public func setDelay(_ delay: Duration?) { self.delay = delay }

    public func export(_ job: ExportJob, into folder: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> ExportedFiles {
        jobs.append(job)
        progress(0)
        if let delay { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        if let error { throw error }
        var files = ExportedFiles(video: nil, audio: nil)
        if job.output.includesVideo {
            let ext = job.sourceVideo?.pathExtension ?? "mov"
            files.video = folder.appending(path: ExportWorkspace.fileName(title: job.title, fallback: job.fallbackTitle, fileExtension: ext))
            try Data("video".utf8).write(to: files.video!)
        }
        if let settings = job.output.audioSettings {
            let name = ExportWorkspace.fileName(title: job.title, fallback: job.fallbackTitle, fileExtension: settings.format.fileExtension)
            files.audio = folder.appending(path: name)
            try Data("audio".utf8).write(to: files.audio!)
        }
        progress(1)
        return files
    }
}
