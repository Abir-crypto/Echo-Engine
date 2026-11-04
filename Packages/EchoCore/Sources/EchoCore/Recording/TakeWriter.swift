import Accelerate
import EchoAudioUnits
import Foundation

/// Moves a take from the capture core's ring into its files, off the render thread (SPEC § 13.3): the raw mixdown
/// (the selected channels summed, or left and right), the processed mixdown and, for several summed channels, each
/// channel on its own.
///
/// Runs on its own queue, not Swift's shared thread pool: renders and exports keep that busy with long synchronous
/// chunks, and a late writer lets the ring overflow (8 s), which loses audio.
actor TakeWriter {
    /// Frames read from the ring at a time.
    static let chunkFrames = 4_096

    private let queue = DispatchSerialQueue(label: "EchoEngine.TakeWriter", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let core: CaptureCore
    private let folder: TakeFolder
    private let configuration: RecordingConfiguration
    private let raw: TakeStream
    private let processed: TakeStream
    private let channelStreams: [TakeStream]
    private let buffers: ReadBuffers
    private let droppedAtStart: Int64
    private var isFinished = false
    /// The processed planes run this many frames behind the raw ones (live processing's constant delay): they are
    /// skipped at the start and made up with silence at the end, so every file shares one timeline.
    private var processedFramesToSkip: Int
    private var rawInputFrames = 0
    private var processedInputFrames = 0

    /// Creates the take's files in `folder`, which must exist; fails without touching files already there.
    init(core: CaptureCore, folder: TakeFolder, configuration: RecordingConfiguration) throws {
        let rate = core.sampleRate
        let mixdownChannels = configuration.mixdownChannelCount
        var created: [URL] = []
        func stream(_ url: URL, channels: Int) throws -> TakeStream {
            let stream = try TakeStream(url: url, channelCount: channels, inputSampleRate: rate, maximumFrames: Self.chunkFrames)
            created.append(url)
            return stream
        }
        do {
            raw = try stream(folder.raw, channels: mixdownChannels)
            processed = try stream(folder.processed, channels: mixdownChannels)
            channelStreams = try configuration.writesChannelFiles
                ? configuration.channels.indices.map { try stream(folder.channel($0 + 1), channels: 1) }
                : []
        } catch {
            let files = FileManager()
            created.forEach { try? files.removeItem(at: $0) }
            throw RecordingError.cantCreateFiles
        }
        self.core = core
        self.folder = folder
        self.configuration = configuration
        buffers = ReadBuffers(planeCount: core.planeCount, frames: Self.chunkFrames)
        droppedAtStart = core.droppedFrames
        processedFramesToSkip = core.processedLatencyFrames
    }

    /// Writes everything queued so far.
    func drain() throws {
        guard !isFinished else { return }
        while true {
            let frames = core.read(into: buffers.planes, maximumFrames: Self.chunkFrames)
            guard frames > 0 else { return }
            try write(frames: frames)
        }
    }

    /// Writes everything queued so far and makes it durable on disk (pause, SPEC § 13.7).
    func flush() throws {
        try drain()
        guard !isFinished else { return }
        for stream in [raw, processed] + channelStreams {
            try stream.synchronize()
        }
    }

    /// Drains every `interval` until cancelled (returns nil), or until the take must end: a write failed, or free space
    /// dropped below `stopBelow` (checked every `storageCheckInterval`, SPEC § 15).
    func run(
        interval: Duration, storageCheckInterval: Duration, clock: any Clock<Duration>, storage: any StorageEstimating, stopBelow: Int64
    ) async -> TakeEndReason? {
        var sinceStorageCheck = Duration.zero
        while !Task.isCancelled {
            do {
                try drain()
            } catch {
                return .writeFailed
            }
            if sinceStorageCheck >= storageCheckInterval {
                sinceStorageCheck = .zero
                if let available = try? storage.availableBytes(), available < stopBelow { return .lowStorage }
            }
            do {
                try await clock.sleep(for: interval)
            } catch {
                return nil
            }
            sinceStorageCheck += interval
        }
        return nil
    }

    /// Writes out what is still queued and closes the files. Best effort after a write failure: everything written
    /// before stays in the take.
    func finish() -> RecordedTake {
        try? drain()
        // The last moment of processed audio is still inside the live chain: silence keeps the files the same length.
        let missing = rawInputFrames - processedInputFrames
        if missing > 0 {
            let silence = [Float](repeating: 0, count: missing)
            silence.withUnsafeBufferPointer { samples in
                let channels = Array(repeating: samples.baseAddress!, count: configuration.mixdownChannelCount)
                try? processed.append(channels, frames: missing)
            }
        }
        isFinished = true
        for stream in [raw, processed] + channelStreams {
            stream.finish()
        }
        return RecordedTake(
            folder: folder,
            duration: Double(min(raw.frameCount, processed.frameCount)) / RecordingConfiguration.sampleRate,
            mixdownChannelCount: configuration.mixdownChannelCount,
            channelFileCount: channelStreams.count,
            droppedFrames: core.droppedFrames - droppedAtStart
        )
    }

    /// Planes: the selected raw channels in take order, then the processed mixdown's channels.
    private func write(frames: Int) throws {
        let selectedCount = configuration.channels.count
        let planes = buffers.planes
        let mixdown = buffers.mixdown
        let plane = { (index: Int) in UnsafePointer(planes[index]!) }
        let rawChannels: [UnsafePointer<Float>]
        switch configuration.mixdown {
        case .stereo:
            rawChannels = [plane(0), plane(1)]
        case .mono where selectedCount == 1:
            rawChannels = [plane(0)]
        case .mono:
            // Same order of additions as the render thread's mixdown, so raw and unprocessed mixdowns match exactly.
            mixdown.update(from: plane(0), count: frames)
            for index in 1..<selectedCount {
                vDSP_vadd(mixdown, 1, plane(index), 1, mixdown, 1, vDSP_Length(frames))
            }
            rawChannels = [UnsafePointer(mixdown)]
        }
        try raw.append(rawChannels, frames: frames)
        rawInputFrames += frames
        let skipped = min(processedFramesToSkip, frames)
        processedFramesToSkip -= skipped
        if skipped < frames {
            let processedChannels = (selectedCount..<selectedCount + configuration.mixdownChannelCount).map { plane($0) + skipped }
            try processed.append(processedChannels, frames: frames - skipped)
            processedInputFrames += frames - skipped
        }
        for (index, stream) in channelStreams.enumerated() {
            try stream.append([plane(index)], frames: frames)
        }
    }
}

/// The writer's read buffers: one pointer per ring plane to `frames` floats, and the raw mono sum.
private final class ReadBuffers {
    let planes: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    let mixdown: UnsafeMutablePointer<Float>
    private let planeCount: Int

    init(planeCount: Int, frames: Int) {
        self.planeCount = planeCount
        planes = .allocate(capacity: planeCount)
        for index in 0..<planeCount {
            planes[index] = .allocate(capacity: frames)
        }
        mixdown = .allocate(capacity: frames)
    }

    deinit {
        for index in 0..<planeCount {
            planes[index]?.deallocate()
        }
        planes.deallocate()
        mixdown.deallocate()
    }
}
