import EchoCore

/// Unlocks everything except `locked`.
public struct FakeEntitlements: EntitlementProvider {
    public var locked: Set<GatedFeature>

    public init(locked: Set<GatedFeature> = []) {
        self.locked = locked
    }

    public func isUnlocked(_ feature: GatedFeature) -> Bool {
        !locked.contains(feature)
    }
}
