import AVFoundation

/// Puts the exported audio into the video (SPEC § 4.3 `ExportService`, § 11.2 step 4).
public protocol VideoRemuxing: Sendable {
    /// Writes `trimRange` of `video` with `audio` (starting at the trim start) as its only sound into `output`, in the
    /// source's container (`output` takes the source's extension). The video is copied, never re-encoded. Reports
    /// progress 0…1 and stops when cancelled; a failed or cancelled remux leaves no file.
    func remux(video: URL, audio: URL, trimRange: TimeRangeCodable, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// `AVMutableComposition` + passthrough `AVAssetExportSession`: video samples, their format (HDR, colour) and the
/// track's orientation stay as they are; file metadata (creation date, location, …) is copied. A trim that starts
/// between keyframes keeps the frames from the keyframe before it and hides them with an edit list.
public struct VideoRemuxer: VideoRemuxing {
    public init() {}

    /// The container of a source video (MOV → MOV, MP4 → MP4, M4V → M4V); `nil` for other files.
    public static func fileType(forVideo url: URL) -> AVFileType? {
        switch url.pathExtension.lowercased() {
        case "mov": .mov
        case "mp4": .mp4
        case "m4v": .m4v
        default: nil
        }
    }

    public func remux(video: URL, audio: URL, trimRange: TimeRangeCodable, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            try await run(video: video, audio: audio, trimRange: trimRange, output: output, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw Task.isCancelled ? CancellationError() : error
        }
    }

    private func run(video: URL, audio: URL, trimRange: TimeRangeCodable, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let fileType = Self.fileType(forVideo: video) else { throw ExportError.unreadableVideo }
        let source = AVURLAsset(url: video)
        let videoTracks: [AVAssetTrack]
        let duration: CMTime
        let metadata: [AVMetadataItem]
        do {
            videoTracks = try await source.loadTracks(withMediaType: .video)
            (duration, metadata) = try await source.load(.duration, .metadata)
        } catch {
            throw ExportError.unreadableVideo
        }
        guard !videoTracks.isEmpty else { throw ExportError.unreadableVideo }
        // Tracks only weakly reference their asset: keep it alive until the composition has its samples.
        let audioAsset = AVURLAsset(url: audio)
        let audioTrack: AVAssetTrack
        let audioRange: CMTimeRange
        do {
            guard let track = try await audioAsset.loadTracks(withMediaType: .audio).first else {
                throw ExportError.unreadableAudio
            }
            audioTrack = track
            audioRange = try await track.load(.timeRange)
        } catch {
            throw ExportError.unreadableAudio
        }

        let timescale: CMTimeScale = 48_000
        let start = CMTime(seconds: max(trimRange.start, 0), preferredTimescale: timescale)
        let end = CMTimeMinimum(CMTime(seconds: trimRange.end, preferredTimescale: timescale), duration)
        let range = CMTimeRange(start: start, end: CMTimeMaximum(end, start))
        let composition = AVMutableComposition()
        do {
            for track in videoTracks {
                guard let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw ExportError.cantWrite
                }
                // A track can end before the asset does (e.g. the last frame's duration); insert only what it has.
                let available = range.intersection(try await track.load(.timeRange))
                if !available.isEmpty {
                    try target.insertTimeRange(available, of: track, at: available.start - range.start)
                }
                target.preferredTransform = try await track.load(.preferredTransform)
            }
            guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ExportError.cantWrite
            }
            let audioDuration = CMTimeMinimum(audioRange.duration, range.duration)
            try target.insertTimeRange(CMTimeRange(start: audioRange.start, duration: audioDuration), of: audioTrack, at: .zero)
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.unreadableVideo
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.cantWrite
        }
        session.metadata = metadata
        try? FileManager.default.removeItem(at: output)
        progress(0)
        let reference = ExportSessionReference(session: session)
        let monitor = Task {
            for await state in reference.session.states(updateInterval: 0.25) {
                if case .exporting(let exporting) = state { progress(min(max(exporting.fractionCompleted, 0), 1)) }
            }
        }
        do {
            try Task.checkCancellation()
            try await session.export(to: output, as: fileType)
        } catch {
            monitor.cancel()
            throw error is CancellationError ? error : ExportError.cantWrite
        }
        monitor.cancel()
        await monitor.value
        progress(1)
    }
}

/// Apple's export API is meant to be watched through `states` while `export` runs, but the session isn't `Sendable`.
private struct ExportSessionReference: @unchecked Sendable {
    let session: AVAssetExportSession
}
