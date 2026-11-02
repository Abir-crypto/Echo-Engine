/// What a video project exports (SPEC § 11.1 "Export as"); audio projects always export audio only.
public enum ExportKind: String, Codable, CaseIterable, Sendable {
    case video, audioOnly, both
}

/// The "Audio quality" presets (SPEC § 11.1).
public enum AudioQuality: String, Codable, CaseIterable, Sendable {
    case standard, high, lossless, custom
}

/// The export sheet's choices, remembered per media type (SPEC § 11.1). "After export" is not remembered: it
/// starts at Keep project every time.
public struct ExportChoices: Codable, Equatable, Sendable {
    public var kind: ExportKind
    public var quality: AudioQuality
    /// The Custom quality's settings.
    public var custom: AudioExportSettings
    public var destination: DestinationKind

    public init(kind: ExportKind, quality: AudioQuality, custom: AudioExportSettings, destination: DestinationKind) {
        self.kind = kind
        self.quality = quality
        self.custom = custom
        self.destination = destination
    }

    /// First-time choices, as the approved export mockup shows them: High quality; video to Photos, audio to Files
    /// (Photos takes only video).
    public static func defaults(for mediaType: MediaType) -> ExportChoices {
        let custom = AudioExportSettings(format: .aac, sampleRate: 48_000, bitDepth: nil, bitrate: 256_000)
        return mediaType == .video
            ? ExportChoices(kind: .video, quality: .high, custom: custom, destination: .photos)
            : ExportChoices(kind: .audioOnly, quality: .high, custom: custom, destination: .files)
    }
}

/// What an export makes (SPEC § 11.1).
public enum ExportOutput: Equatable, Sendable {
    /// The video with new AAC audio at this bitrate.
    case video(audioBitrate: Int)
    case audioOnly(AudioExportSettings)
    /// The video and an audio file.
    case both(audioBitrate: Int, AudioExportSettings)

    public var includesVideo: Bool {
        if case .audioOnly = self { return false }
        return true
    }

    /// The AAC bitrate of the audio inside the video; `nil` without video.
    public var videoAudioBitrate: Int? {
        switch self {
        case .video(let bitrate), .both(let bitrate, _): bitrate
        case .audioOnly: nil
        }
    }

    /// The audio file's settings; `nil` without an audio file.
    public var audioSettings: AudioExportSettings? {
        switch self {
        case .audioOnly(let settings), .both(_, let settings): settings
        case .video: nil
        }
    }
}

/// What happens to the project once the export is delivered (SPEC § 11.1); never before (§ 11.2 step 6).
public enum PostExportAction: String, CaseIterable, Sendable {
    case keepProject, keepProjectClearCache, deleteProject
}

extension ExportChoices {
    /// The audio file's settings for the chosen quality.
    public var audioSettings: AudioExportSettings {
        switch quality {
        case .standard: .standard
        case .high: .high
        case .lossless: .lossless
        case .custom: custom
        }
    }

    /// The AAC bitrate inside an exported video (user decision, SPEC § 11.1): Standard 192, High and Lossless 320,
    /// Custom its AAC bitrate, or 256 when Custom isn't AAC.
    public var videoAudioBitrate: Int {
        switch quality {
        case .standard: 192_000
        case .high, .lossless: 320_000
        case .custom: custom.format == .aac ? custom.bitrate ?? Self.defaultVideoAudioBitrate : Self.defaultVideoAudioBitrate
        }
    }

    public static let defaultVideoAudioBitrate = 256_000

    /// What these choices export for a project of `mediaType`: audio projects always export audio only.
    public func output(for mediaType: MediaType) -> ExportOutput {
        guard mediaType == .video else { return .audioOnly(audioSettings) }
        switch kind {
        case .video: return .video(audioBitrate: videoAudioBitrate)
        case .audioOnly: return .audioOnly(audioSettings)
        case .both: return .both(audioBitrate: videoAudioBitrate, audioSettings)
        }
    }
}
