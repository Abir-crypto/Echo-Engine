/// Everything undo/redo snapshots (SPEC § 5.2, § 6.5).
public struct EditState: Codable, Equatable, Sendable {
    public var aiStack: [AIOperation]
    public var manual: ManualSettings
    public var trimRange: TimeRangeCodable
    public var outputLoudness: LoudnessTarget?

    public init(
        aiStack: [AIOperation],
        manual: ManualSettings,
        trimRange: TimeRangeCodable,
        outputLoudness: LoudnessTarget?
    ) {
        self.aiStack = aiStack
        self.manual = manual
        self.trimRange = trimRange
        self.outputLoudness = outputLoudness
    }
}
