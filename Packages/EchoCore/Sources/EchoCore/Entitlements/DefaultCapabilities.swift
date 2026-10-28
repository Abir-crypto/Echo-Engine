/// v1: every supported device (iPhone 11 and later) runs every feature.
public struct DefaultCapabilities: DeviceCapabilityChecking {
    public init() {}

    public func supports(_ feature: GatedFeature) -> Bool {
        true
    }
}
