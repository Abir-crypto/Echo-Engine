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
