/// Audio export formats (SPEC § 11.1). MP3 export is not supported.
public enum AudioFormat: String, Codable, CaseIterable, Sendable {
    case aac, wav, flac, alac

    public var fileExtension: String {
        switch self {
        case .aac, .alac: "m4a"
        case .wav: "wav"
        case .flac: "flac"
        }
    }

    /// WAV, FLAC and ALAC keep every sample (at their bit depth); AAC is lossy.
    public var isLossless: Bool { self != .aac }
}

/// How exported audio is encoded (SPEC § 11.1): a bit depth for WAV/FLAC/ALAC, a bitrate for AAC.
public struct AudioExportSettings: Codable, Equatable, Hashable, Sendable {
    public var format: AudioFormat
    /// 44,100 or 48,000 Hz.
    public var sampleRate: Double
    /// 16 or 24 for lossless formats and WAV; `nil` for AAC.
    public var bitDepth: Int?
    /// Bits per second for AAC (128, 192, 256 or 320 kbps); `nil` otherwise.
    public var bitrate: Int?

    public init(format: AudioFormat, sampleRate: Double, bitDepth: Int?, bitrate: Int?) {
        self.format = format
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.bitrate = bitrate
    }

    public static let sampleRates: [Double] = [44_100, 48_000]
    public static let bitDepths = [16, 24]
    public static let aacBitrates = [128_000, 192_000, 256_000, 320_000]

    /// "Standard": AAC 192 kbps.
    public static let standard = AudioExportSettings(format: .aac, sampleRate: 48_000, bitDepth: nil, bitrate: 192_000)
    /// "High": AAC 320 kbps.
    public static let high = AudioExportSettings(format: .aac, sampleRate: 48_000, bitDepth: nil, bitrate: 320_000)
    /// "Lossless": FLAC 24-bit 48 kHz.
    public static let lossless = AudioExportSettings(format: .flac, sampleRate: 48_000, bitDepth: 24, bitrate: nil)

    /// Whether these are choices the export sheet offers.
    public var isSupported: Bool {
        guard Self.sampleRates.contains(sampleRate) else { return false }
        if format.isLossless {
            return bitDepth.map(Self.bitDepths.contains) ?? false
        }
        return bitrate.map(Self.aacBitrates.contains) ?? false
    }
}
