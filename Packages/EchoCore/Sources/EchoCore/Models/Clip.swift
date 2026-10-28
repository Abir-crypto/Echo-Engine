import Foundation

/// A span of the source with its own processing. v1 projects have exactly one clip covering the full
/// source; the array is a hook for clips/splitting later (SPEC § 2.2, § 5.2).
public struct Clip: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    /// v1: the full source.
    public var sourceRange: TimeRangeCodable
    /// User-ordered; processed top to bottom.
    public var aiStack: [AIOperation]
    public var manual: ManualSettings

    public init(
        id: UUID = UUID(),
        sourceRange: TimeRangeCodable,
        aiStack: [AIOperation] = [],
        manual: ManualSettings = ManualSettings()
    ) {
        self.id = id
        self.sourceRange = sourceRange
        self.aiStack = aiStack
        self.manual = manual
    }
}
