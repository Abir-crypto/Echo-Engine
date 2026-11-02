import AVFoundation
import CEchoDSP

/// Auto Level (SPEC § 6.7): the static gain that brings the processed audio (AI render + manual chain) to the
/// loudness target over the trim range.
public protocol AutoLevelAnalyzing: Sendable {
    /// The gain in dB, within ±20 (user decision, SPEC § 6.7); 0 when nothing is loud enough to measure. Reports
    /// progress 0…1 and stops when cancelled.
    func gain(
        of audio: URL, manual: ManualSettings, range: TimeRangeCodable, target: LoudnessTarget, progress: @Sendable (Double) -> Void
    ) async throws -> Double
}

extension AutoLevelAnalyzing {
    public func gain(of audio: URL, manual: ManualSettings, range: TimeRangeCodable, target: LoudnessTarget) async throws -> Double {
        try await gain(of: audio, manual: manual, range: range, target: target, progress: { _ in })
    }
}

public struct AutoLevelAnalyzer: AutoLevelAnalyzing {
    public static let gainRange: ClosedRange<Double> = -20...20

    public init() {}

    public func gain(
        of audio: URL, manual: ManualSettings, range: TimeRangeCodable, target: LoudnessTarget, progress: @Sendable (Double) -> Void
    ) async throws -> Double {
        let measurement = try await LoudnessScan.measure(audio, range: range, measuresTruePeak: false, progress: progress) { sampleRate, channels in
            try OfflineEffectChain(manual: manual, outputStage: nil, sampleRate: sampleRate, channelCount: channels)
        }
        guard let loudness = measurement.integratedLUFS else { return 0 }
        return min(max(target.lufs - loudness, Self.gainRange.lowerBound), Self.gainRange.upperBound)
    }
}

/// Reads a file range one second at a time into a `LoudnessMeter`, optionally through a transform first.
enum LoudnessScan {
    static func measure(
        _ audio: URL,
        range: TimeRangeCodable,
        measuresTruePeak: Bool,
        progress: @Sendable (Double) -> Void,
        transform makeTransform: ((_ sampleRate: Double, _ channels: Int) throws -> any ChunkTransform)? = nil
    ) async throws -> LoudnessMeasurement {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audio)
        } catch {
            throw LoudnessError.unreadable
        }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let frames = range.frames(sampleRate: sampleRate, length: file.length)
        let start = frames.lowerBound, end = frames.upperBound
        let chunkFrames = AVAudioFrameCount(sampleRate)
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw LoudnessError.unreadable
        }
        var transform = try makeTransform?(sampleRate, channelCount)
        var meter = echo.dsp.LoudnessMeter()
        meter.prepare(sampleRate, Int32(channelCount), measuresTruePeak)
        func feed(_ channels: [[Float]]) {
            guard let frames = channels.first?.count, frames > 0 else { return }
            let storage = channels.map { samples -> UnsafeMutablePointer<Float> in
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                pointer.initialize(from: samples, count: frames)
                return pointer
            }
            defer { storage.forEach { $0.deallocate() } }
            let pointers = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: storage.count)
            defer { pointers.deallocate() }
            for (index, pointer) in storage.enumerated() { pointers[index] = UnsafePointer(pointer) }
            meter.process(pointers, Int32(storage.count), Int32(frames))
        }
        file.framePosition = start
        progress(0)
        while file.framePosition < end {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), end - file.framePosition))
            do {
                try file.read(into: chunk, frameCount: frames)
            } catch {
                throw LoudnessError.unreadable
            }
            guard chunk.frameLength > 0, let data = chunk.floatChannelData else { break }
            if transform == nil {
                let channels = UnsafeRawPointer(data).assumingMemoryBound(to: UnsafePointer<Float>?.self)
                meter.process(channels, Int32(channelCount), Int32(chunk.frameLength))
            } else {
                let channels = (0..<channelCount).map { Array(UnsafeBufferPointer(start: data[$0], count: Int(chunk.frameLength))) }
                feed(try transform!.process(channels))
            }
            progress(Double(file.framePosition - start) / Double(max(end - start, 1)))
        }
        if transform != nil { feed(try transform!.finish()) }
        progress(1)
        let integrated = meter.integratedLUFS()
        return LoudnessMeasurement(integratedLUFS: integrated.isNaN ? nil : integrated, truePeakDBTP: meter.truePeakDBTP())
    }
}
