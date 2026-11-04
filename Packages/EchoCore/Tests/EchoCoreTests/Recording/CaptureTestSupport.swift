import AVFoundation
import EchoAudioUnits
import Foundation
import Synchronization
@testable import EchoCore

/// Fixed-size channel memory for driving a `CaptureCore` like a render callback. Pointer arrays are built up front, so
/// `process` and `read` themselves allocate nothing.
final class CaptureHarness {
    let core: CaptureCore
    let frames: Int
    private let inputs: [UnsafeMutablePointer<Float>]
    private let outputs: [UnsafeMutablePointer<Float>]
    private let planes: [UnsafeMutablePointer<Float>]
    private let inputPointers: UnsafeMutablePointer<UnsafePointer<Float>?>
    private let outputPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let planePointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    /// `frames` is the most frames one `process` or `read` handles.
    init(core: CaptureCore, frames: Int) {
        self.core = core
        self.frames = frames
        inputs = (0..<core.inputChannelCount).map { _ in .allocate(capacity: frames) }
        outputs = (0..<core.mixdownChannelCount).map { _ in .allocate(capacity: frames) }
        planes = (0..<core.planeCount).map { _ in .allocate(capacity: frames) }
        inputPointers = .allocate(capacity: max(1, inputs.count))
        outputPointers = .allocate(capacity: max(1, outputs.count))
        planePointers = .allocate(capacity: max(1, planes.count))
        for (index, input) in inputs.enumerated() { inputPointers[index] = UnsafePointer(input) }
        for (index, output) in outputs.enumerated() { outputPointers[index] = output }
        for (index, plane) in planes.enumerated() { planePointers[index] = plane }
    }

    deinit {
        (inputs + outputs + planes).forEach { $0.deallocate() }
        inputPointers.deallocate()
        outputPointers.deallocate()
        planePointers.deallocate()
    }

    /// Sets the next block's input: `value(channel, frame)` for `count` frames.
    func fill(_ count: Int, _ value: (Int, Int) -> Float) {
        for (channel, input) in inputs.enumerated() {
            for frame in 0..<count { input[frame] = value(channel, frame) }
        }
    }

    /// One render cycle over the filled input. Allocation-free.
    func process(_ count: Int) {
        core.process(input: inputPointers, output: outputPointers, frameCount: count)
    }

    /// One read into the plane buffers. Allocation-free.
    func readOnce() -> Int {
        core.read(into: planePointers, maximumFrames: frames)
    }

    /// The last block's monitor output.
    func output(_ count: Int) -> [[Float]] {
        outputs.map { Array(UnsafeBufferPointer(start: $0, count: count)) }
    }

    /// Reads until nothing is queued, one array per plane.
    func readAll() -> [[Float]] {
        var result = [[Float]](repeating: [], count: planes.count)
        while true {
            let count = readOnce()
            guard count > 0 else { return result }
            for (index, plane) in planes.enumerated() { result[index] += UnsafeBufferPointer(start: plane, count: count) }
        }
    }
}

/// Supplies an offline engine's input node (`setManualRenderingInputPVMBlock`) from `signal(channel, frame)`, frame
/// counting from 0 across calls.
final class SignalInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    private let signal: @Sendable (Int, Int) -> Float
    private let position = Mutex(0)

    init(format: AVAudioFormat, signal: @escaping @Sendable (Int, Int) -> Float) {
        buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
        self.signal = signal
    }

    /// Frames supplied so far.
    var framesSupplied: Int { position.withLock { $0 } }

    func next(_ frameCount: AVAudioFrameCount) -> UnsafePointer<AudioBufferList> {
        let start = position.withLock { position in
            defer { position += Int(frameCount) }
            return position
        }
        buffer.frameLength = frameCount
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(frameCount) {
                buffer.floatChannelData![channel][frame] = signal(channel, start + frame)
            }
        }
        return UnsafePointer(buffer.audioBufferList)
    }
}

/// Free space that a test changes while a take runs.
final class ChangingStorage: StorageEstimating {
    private let bytes: Mutex<Int64>

    init(available: Int64) {
        bytes = Mutex(available)
    }

    func set(_ available: Int64) {
        bytes.withLock { $0 = available }
    }

    func bytesToImport(_ source: SourceInfo) -> Int64 { 0 }
    func bytesToEdit(_ project: Project) -> Int64 { 0 }
    func bytesToExport(_ project: Project) -> Int64 { 0 }
    func bytesToExport(_ project: Project, output: ExportOutput) -> Int64 { 0 }
    func availableBytes() throws -> Int64 { bytes.withLock { $0 } }
}

/// Every sample of a file, one array per channel.
func readSamples(_ url: URL) throws -> (format: AVAudioFormat, channels: [[Float]]) {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192)!
    var channels = [[Float]](repeating: [], count: Int(file.processingFormat.channelCount))
    // One read may return fewer frames than asked for.
    while file.framePosition < file.length {
        try file.read(into: buffer)
        guard buffer.frameLength > 0 else { break }
        for index in channels.indices {
            channels[index] += UnsafeBufferPointer(start: buffer.floatChannelData![index], count: Int(buffer.frameLength))
        }
    }
    return (file.fileFormat, channels)
}

/// A new empty folder in the temporary directory.
func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "EchoRecordingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
