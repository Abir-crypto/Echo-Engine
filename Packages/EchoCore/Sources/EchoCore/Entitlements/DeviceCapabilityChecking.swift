/// Decides whether the current device can run a feature (SPEC § 4.8).
public protocol DeviceCapabilityChecking: Sendable {
    func supports(_ feature: GatedFeature) -> Bool
}
