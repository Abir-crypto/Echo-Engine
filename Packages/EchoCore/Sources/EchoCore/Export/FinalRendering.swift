import Foundation

/// What the final render needs from a project (SPEC § 11.2).
public struct FinalRenderRequest: Equatable, Sendable {
    /// The current AI render (the full stack's output), or `working.caf` when the stack is empty: 48 kHz audio.
    public var audio: URL
    public var manual: ManualSettings
    public var trimRange: TimeRangeCodable
    /// Auto Level's target; `nil` = off.
    public var outputLoudness: LoudnessTarget?

    public init(audio: URL, manual: ManualSettings, trimRange: TimeRangeCodable, outputLoudness: LoudnessTarget?) {
        self.audio = audio
        self.manual = manual
        self.trimRange = trimRange
        self.outputLoudness = outputLoudness
    }
}

/// The export's offline final render (SPEC § 4.3 `ExportService`, § 11.2 step 2).
public protocol FinalRendering: Sendable {
    /// Renders the trim range of `request.audio` through the manual chain, Auto Level gain (measured again, exactly)
    /// and the true-peak limiter into `output`, an ALAC 24-bit 48 kHz file with the input's channels. Reports
    /// progress 0…1 once over analysis and rendering; a failed or cancelled render leaves no file.
    func render(_ request: FinalRenderRequest, to output: URL, progress: @Sendable (Double) -> Void) async throws
}

/// Runs the same C++ effects as playback through `OfflineEffectChain`, the chain Auto Level measures with, so the
/// export lands on the gain it was measured for (user decision, SPEC § 11.2). The limiter is always on (SPEC § 8).
public struct FinalRenderer: FinalRendering {
    /// The part of the progress bar Auto Level's analysis pass takes when a target is set.
    static let analysisShare = 0.4

    private let autoLevel: any AutoLevelAnalyzing

    public init(autoLevel: any AutoLevelAnalyzing) {
        self.autoLevel = autoLevel
    }

    public func render(_ request: FinalRenderRequest, to output: URL, progress: @Sendable (Double) -> Void) async throws {
        let gain: Double
        let renderStart: Double
        if let target = request.outputLoudness {
            gain = try await autoLevel.gain(
                of: request.audio, manual: request.manual, range: request.trimRange, target: target
            ) { fraction in
                progress(min(max(fraction, 0), 1) * Self.analysisShare)
            }
            renderStart = Self.analysisShare
        } else {
            gain = 0
            renderStart = 0
        }
        let manual = request.manual
        try await ChunkedRender.run(input: request.audio, output: output, range: request.trimRange) { fraction in
            progress(renderStart + min(max(fraction, 0), 1) * (1 - renderStart))
        } makeTransform: { channelCount in
            try OfflineEffectChain(
                manual: manual,
                outputStage: .init(autoLevelGainDB: gain),
                sampleRate: ChunkedRender.sampleRate,
                channelCount: channelCount
            )
        }
    }
}
