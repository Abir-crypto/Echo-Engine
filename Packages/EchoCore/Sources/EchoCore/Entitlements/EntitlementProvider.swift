/// Decides whether the user is entitled to a feature (hook for paid tiers, SPEC § 2.2).
public protocol EntitlementProvider: Sendable {
    func isUnlocked(_ feature: GatedFeature) -> Bool
}
