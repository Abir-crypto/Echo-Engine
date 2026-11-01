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

extension Project {
    /// The undoable part of the project: the (single, v1) clip's AI stack and manual settings, trim and loudness.
    public var editState: EditState {
        get {
            EditState(aiStack: clips[0].aiStack, manual: clips[0].manual, trimRange: trimRange, outputLoudness: outputLoudness)
        }
        set {
            clips[0].aiStack = newValue.aiStack
            clips[0].manual = newValue.manual
            trimRange = newValue.trimRange
            outputLoudness = newValue.outputLoudness
        }
    }
}
