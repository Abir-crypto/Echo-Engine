/// Undo/redo for one editor session (SPEC § 6.5): linear stacks of full `EditState` snapshots, at most 30 undo
/// steps. A new change after an undo discards the redo branch. Unlike Foundation's `UndoManager`, every state can be
/// listed, which the render janitor needs to keep their renders (SPEC § 6.4).
public struct EditHistory: Equatable, Sendable {
    public static let maxSteps = 30

    public private(set) var undoStates: [EditState] = []
    public private(set) var redoStates: [EditState] = []

    public init() {}

    public var canUndo: Bool { !undoStates.isEmpty }
    public var canRedo: Bool { !redoStates.isEmpty }

    /// Every state in the history, oldest undo step first.
    public var allStates: [EditState] { undoStates + redoStates.reversed() }

    /// Records the state before a change as one undo step and clears redo.
    public mutating func record(before state: EditState) {
        undoStates.append(state)
        if undoStates.count > Self.maxSteps {
            undoStates.removeFirst(undoStates.count - Self.maxSteps)
        }
        redoStates.removeAll()
    }

    /// The state to restore; `current` becomes the next redo step.
    public mutating func undo(from current: EditState) -> EditState? {
        guard let previous = undoStates.popLast() else { return nil }
        redoStates.append(current)
        return previous
    }

    /// The state to restore; `current` becomes the next undo step.
    public mutating func redo(from current: EditState) -> EditState? {
        guard let next = redoStates.popLast() else { return nil }
        undoStates.append(current)
        return next
    }
}
