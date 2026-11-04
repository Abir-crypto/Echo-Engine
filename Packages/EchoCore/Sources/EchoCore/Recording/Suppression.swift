import CEchoDSP

/// Noise reduction while recording (SPEC § 13.4).
public enum SuppressionLevel: String, Codable, Sendable, CaseIterable {
    case off
    /// Apple voice processing on the input plus a noise gate.
    case standard
    /// RNNoise live.
    case high
}

/// What the engine runs for the chosen level (SPEC § 13.4).
public struct SuppressionState: Equatable, Sendable {
    /// The person's choice.
    public var level: SuppressionLevel
    /// What runs: High below 44.1 kHz (a Bluetooth headset) runs as Standard.
    public var effective: SuppressionLevel
    /// Standard with Apple voice processing; false means the noise gate alone (an input with several channels, or voice
    /// processing unavailable), which the Noise reduction row says.
    public var usesVoiceProcessing: Bool

    public init(level: SuppressionLevel, effective: SuppressionLevel, usesVoiceProcessing: Bool) {
        self.level = level
        self.effective = effective
        self.usesVoiceProcessing = usesVoiceProcessing
    }

    public static let off = SuppressionState(level: .off, effective: .off, usesVoiceProcessing: false)

    /// Standard is running without voice processing.
    public var isGateOnly: Bool { effective == .standard && !usesVoiceProcessing }
}

extension SuppressionLevel {
    /// The capture unit's `EECaptureParameterSuppression` value.
    var parameterValue: Float {
        switch self {
        case .off: 0
        case .standard: 1
        case .high: 2
        }
    }
}
