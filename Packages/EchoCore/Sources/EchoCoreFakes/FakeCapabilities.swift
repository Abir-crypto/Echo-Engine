import EchoCore

/// Supports everything except `unsupported`.
public struct FakeCapabilities: DeviceCapabilityChecking {
    public var unsupported: Set<GatedFeature>

    public init(unsupported: Set<GatedFeature> = []) {
        self.unsupported = unsupported
    }

    public func supports(_ feature: GatedFeature) -> Bool {
        !unsupported.contains(feature)
    }
}
