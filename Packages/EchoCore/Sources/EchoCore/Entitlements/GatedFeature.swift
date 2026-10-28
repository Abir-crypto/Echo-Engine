/// A feature that is checked against `EntitlementProvider` and `DeviceCapabilityChecking`
/// before use: every AI button and every export path (SPEC § 4.8).
public enum GatedFeature: String, CaseIterable, Sendable {
    case noiseSuppression
    case clearVoice
    case voiceLeveler
    case exportVideo
    case exportAudio
}
