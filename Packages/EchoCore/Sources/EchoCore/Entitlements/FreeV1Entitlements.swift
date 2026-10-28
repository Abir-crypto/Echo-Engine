/// v1: everything is free.
public struct FreeV1Entitlements: EntitlementProvider {
    public init() {}

    public func isUnlocked(_ feature: GatedFeature) -> Bool {
        true
    }
}
