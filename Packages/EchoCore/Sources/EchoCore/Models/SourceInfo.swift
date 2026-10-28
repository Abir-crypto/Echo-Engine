/// Technical facts about an imported or recorded source file (SPEC § 5.2).
public struct SourceInfo: Codable, Equatable, Sendable {
    /// Seconds.
    public var duration: Double
    /// Uniform type identifier of the container, e.g. `com.apple.quicktime-movie`.
    public var container: String
    /// Four-character code of the audio track, e.g. `aac `.
    public var audioCodec: String
    /// Four-character code of the video track; `nil` for audio sources.
    public var videoCodec: String?
    public var byteSize: Int64
    public var channelCount: Int
    /// Hz.
    public var sampleRate: Double

    public init(
        duration: Double,
        container: String,
        audioCodec: String,
        videoCodec: String?,
        byteSize: Int64,
        channelCount: Int,
        sampleRate: Double
    ) {
        self.duration = duration
        self.container = container
        self.audioCodec = audioCodec
        self.videoCodec = videoCodec
        self.byteSize = byteSize
        self.channelCount = channelCount
        self.sampleRate = sampleRate
    }
}
