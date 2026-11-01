import EchoCore
import EchoCoreFakes
import Foundation
import Testing

struct EditHistoryTests {
    /// Distinct states told apart by their trim start.
    private func state(_ start: Double) -> EditState {
        EditState(aiStack: [], manual: ManualSettings(), trimRange: TimeRangeCodable(start: start, duration: 10), outputLoudness: nil)
    }

    @Test func undoAndRedoWalkTheHistory() {
        var history = EditHistory()
        history.record(before: state(0))
        history.record(before: state(1))

        #expect(history.undo(from: state(2)) == state(1))
        #expect(history.undo(from: state(1)) == state(0))
        #expect(history.undo(from: state(0)) == nil)
        #expect(history.redo(from: state(0)) == state(1))
        #expect(history.redo(from: state(1)) == state(2))
        #expect(history.redo(from: state(2)) == nil)
    }

    @Test func aNewChangeAfterUndoDiscardsRedo() {
        var history = EditHistory()
        history.record(before: state(0))
        _ = history.undo(from: state(1))
        #expect(history.canRedo)

        history.record(before: state(0))

        #expect(!history.canRedo)
        #expect(history.allStates == [state(0)])
    }

    @Test func keepsAtMostThirtySteps() {
        var history = EditHistory()
        for step in 0..<35 {
            history.record(before: state(Double(step)))
        }
        #expect(history.undoStates.count == 30)
        #expect(history.undoStates.first == state(5))
    }

    @Test func allStatesIsTheTimelineWithoutTheCurrentState() {
        var history = EditHistory()
        history.record(before: state(0))
        history.record(before: state(1))
        #expect(history.allStates == [state(0), state(1)])

        _ = history.undo(from: state(2))
        #expect(history.allStates == [state(0), state(2)], "current is 1")

        _ = history.undo(from: state(1))
        #expect(history.allStates == [state(1), state(2)], "current is 0")
    }

    @Test func projectEditStateReadsAndWritesTheClip() {
        var project = PreviewProjects.all()[1]
        var edited = project.editState
        edited.trimRange = TimeRangeCodable(start: 3, duration: 4)
        edited.manual.inputGainDB = 6
        edited.outputLoudness = .podcast

        project.editState = edited

        #expect(project.trimRange == TimeRangeCodable(start: 3, duration: 4))
        #expect(project.clips[0].manual.inputGainDB == 6)
        #expect(project.outputLoudness == .podcast)
        #expect(project.editState == edited)
    }
}
