import Foundation

/// One export (SPEC § 11.2): the project's current audio and settings, and what to make.
public struct ExportJob: Equatable, Sendable {
    /// The current AI render, or `working.caf` without AI steps.
    public var audio: URL
    /// The imported original; video projects only.
    public var sourceVideo: URL?
    public var manual: ManualSettings
    public var trimRange: TimeRangeCodable
    public var outputLoudness: LoudnessTarget?
    public var output: ExportOutput
    /// Names the files (made safe by `ExportWorkspace.fileName`); `fallbackTitle` (localized) when it's empty.
    public var title: String
    public var fallbackTitle: String

    public init(
        audio: URL, sourceVideo: URL?, manual: ManualSettings, trimRange: TimeRangeCodable, outputLoudness: LoudnessTarget?,
        output: ExportOutput, title: String, fallbackTitle: String
    ) {
        self.audio = audio
        self.sourceVideo = sourceVideo
        self.manual = manual
        self.trimRange = trimRange
        self.outputLoudness = outputLoudness
        self.output = output
        self.title = title
        self.fallbackTitle = fallbackTitle
    }
}

/// The finished files, ready to deliver.
public struct ExportedFiles: Equatable, Sendable {
    public var video: URL?
    public var audio: URL?

    public init(video: URL?, audio: URL?) {
        self.video = video
        self.audio = audio
    }

    /// The video first.
    public var all: [URL] { [video, audio].compactMap(\.self) }
}

/// Offline final render + encode + remux (SPEC § 4.3, § 11.2 steps 2–4).
public protocol ExportService: Sendable {
    /// Makes the job's files in `folder` (an empty export folder). Reports progress 0…1 and stops when cancelled;
    /// the caller removes the folder when the export ends.
    func export(_ job: ExportJob, into folder: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> ExportedFiles
}

/// Renders the trim range once, then encodes it for the video (AAC at its bitrate, remuxed into the source's
/// container) and/or as the audio file. Work files stay in a hidden subfolder that is removed at the end.
public struct AVExportService: ExportService {
    private let renderer: any FinalRendering
    private let encoder: any AudioEncoding
    private let remuxer: any VideoRemuxing

    public init(renderer: any FinalRendering, encoder: any AudioEncoding, remuxer: any VideoRemuxing) {
        self.renderer = renderer
        self.encoder = encoder
        self.remuxer = remuxer
    }

    public func export(_ job: ExportJob, into folder: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> ExportedFiles {
        var video: (source: URL, bitrate: Int)?
        if let bitrate = job.output.videoAudioBitrate {
            guard let source = job.sourceVideo, VideoRemuxer.fileType(forVideo: source) != nil else { throw ExportError.unreadableVideo }
            video = (source, bitrate)
        }
        let files = FileManager()
        let work = folder.appending(path: ".work", directoryHint: .isDirectory)
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: work) }
        let stages = StagedProgress(
            weights: [4, video == nil ? 0 : 1, video == nil ? 0 : 1, job.output.audioSettings == nil ? 0 : 1], report: progress
        )
        progress(0)

        let rendered = work.appending(path: "final.m4a")
        let request = FinalRenderRequest(audio: job.audio, manual: job.manual, trimRange: job.trimRange, outputLoudness: job.outputLoudness)
        try await renderer.render(request, to: rendered) { stages.report(0, $0) }

        var result = ExportedFiles(video: nil, audio: nil)
        if let video {
            let audio = work.appending(path: "video-audio.m4a")
            let aac = AudioExportSettings(format: .aac, sampleRate: 48_000, bitDepth: nil, bitrate: video.bitrate)
            try await encoder.encode(rendered, to: audio, settings: aac) { stages.report(1, $0) }
            let name = ExportWorkspace.fileName(title: job.title, fallback: job.fallbackTitle, fileExtension: video.source.pathExtension.lowercased())
            let output = folder.appending(path: name)
            try await remuxer.remux(video: video.source, audio: audio, trimRange: job.trimRange, to: output) { stages.report(2, $0) }
            result.video = output
        }
        if let settings = job.output.audioSettings {
            let name = ExportWorkspace.fileName(title: job.title, fallback: job.fallbackTitle, fileExtension: settings.format.fileExtension)
            let output = folder.appending(path: name)
            try await encoder.encode(rendered, to: output, settings: settings) { stages.report(3, $0) }
            result.audio = output
        }
        progress(1)
        return result
    }
}

/// One progress bar over weighted stages, each reporting 0…1.
private struct StagedProgress: Sendable {
    let weights: [Double]
    let report: @Sendable (Double) -> Void

    func report(_ stage: Int, _ fraction: Double) {
        let total = weights.reduce(0, +)
        guard total > 0 else { return }
        let before = weights.prefix(stage).reduce(0, +)
        report((before + min(max(fraction, 0), 1) * weights[stage]) / total)
    }
}
