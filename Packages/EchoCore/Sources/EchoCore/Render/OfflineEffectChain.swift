import CEchoDSP
import Foundation

/// The preview's effects run offline (SPEC § 6.7 analysis, F08 export): the manual chain and, when given an output
/// stage, Auto Level gain + the true-peak limiter. The same C++ effects as playback; their latency is removed, so the
/// output lines up with the input and is as long.
final class OfflineEffectChain: ChunkTransform {
    struct OutputStage {
        var autoLevelGainDB: Double
    }

    private var effects: [OpaquePointer] = []
    private let latency: Int
    private let channelCount: Int
    private var skipped = 0
    private var inputCount = 0
    private var outputCount = 0
    private static let maximumFrames: Int32 = 4_096

    init(manual: ManualSettings, outputStage: OutputStage?, sampleRate: Double, channelCount: Int) throws {
        self.channelCount = channelCount
        guard let chain = EEEffectCreate(.manualChain) else { throw RenderError.processorUnavailable }
        effects.append(chain)
        for (address, value) in manual.manualChainParameterValues {
            EEEffectSetParameter(chain, address, value)
        }
        if let outputStage {
            guard let limiter = EEEffectCreate(.outputLimiter) else { throw RenderError.processorUnavailable }
            effects.append(limiter)
            EEEffectSetParameter(limiter, EEOutputLimiterParameter.ceiling.rawValue, manual.limiter.ceilingDB)
            EEEffectSetParameter(limiter, EEOutputLimiterParameter.gain.rawValue, Float(outputStage.autoLevelGainDB))
        }
        for effect in effects {
            EEEffectPrepare(effect, sampleRate, Int32(channelCount), Self.maximumFrames)
        }
        latency = effects.reduce(0) { $0 + Int(EEEffectLatencyFrames($1)) }
    }

    deinit {
        effects.forEach { EEEffectDestroy($0) }
    }

    func process(_ channels: [[Float]]) -> [[Float]] {
        inputCount += channels.first?.count ?? 0
        return run(channels)
    }

    /// Pushes silence through until the output is as long as the input.
    func finish() -> [[Float]] {
        var tail: [[Float]] = Array(repeating: [], count: channelCount)
        while outputCount < inputCount {
            let silence = Array(repeating: [Float](repeating: 0, count: max(latency, 1)), count: channelCount)
            let more = run(silence)
            for index in tail.indices { tail[index] += more[index] }
        }
        return tail
    }

    private func run(_ channels: [[Float]]) -> [[Float]] {
        guard let frames = channels.first?.count, frames > 0 else { return channels }
        let storage = channels.map { samples -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            pointer.initialize(from: samples, count: frames)
            return pointer
        }
        defer { storage.forEach { $0.deallocate() } }
        let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: storage.count)
        defer { pointers.deallocate() }
        for (index, pointer) in storage.enumerated() { pointers[index] = pointer }
        for effect in effects {
            EEEffectProcess(effect, pointers, Int32(storage.count), Int32(frames))
        }
        // The first `latency` frames out are the effects' delay; drop them, and never return more than came in.
        let skip = min(latency - skipped, frames)
        skipped += skip
        let count = min(frames - skip, inputCount - outputCount)
        guard count > 0 else { return Array(repeating: [], count: storage.count) }
        outputCount += count
        return storage.map { Array(UnsafeBufferPointer(start: $0 + skip, count: count)) }
    }
}
