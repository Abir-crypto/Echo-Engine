/// A feature that is checked against `EntitlementProvider` and `DeviceCapabilityChecking`
/// before use: every AI button and every export path (SPEC § 4.8).
public enum GatedFeature: String, CaseIterable, Sendable {
    case noiseSuppression
    case clearVoice
    case voiceLeveler
    case exportVideo
    case exportAudio
}

extension AIFeature {
    /// The gate this AI feature is checked against (SPEC § 4.8); `nil` for features from newer versions.
    public var gatedFeature: GatedFeature? {
        switch self {
        case .noiseSuppression: .noiseSuppression
        case .clearVoice: .clearVoice
        case .voiceLeveler: .voiceLeveler
        case .unknown: nil
        }
    }
}
