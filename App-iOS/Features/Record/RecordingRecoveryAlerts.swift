import SwiftUI

extension View {
    /// The "Recover recording?" alert, its delete confirmation and the failure message (SPEC § 13.3).
    func recordingRecoveryAlerts(_ model: RecordingRecoveryModel) -> some View {
        modifier(RecordingRecoveryAlerts(model: model))
    }
}

private struct RecordingRecoveryAlerts: ViewModifier {
    let model: RecordingRecoveryModel

    func body(content: Content) -> some View {
        content
            .alert(
                Text("Recover recording?", comment: "Alert title at launch: a recording didn't finish because the app closed."),
                isPresented: Binding(get: { model.offered != nil }, set: { if !$0 { model.notNow() } }),
                presenting: model.offered
            ) { _ in
                Button {
                    model.recover()
                } label: {
                    Text("Recover", comment: "Makes a project of an unfinished recording and opens it.")
                }
                Button(role: .destructive) {
                    model.askToDelete()
                } label: {
                    Text("Delete…", comment: "Deletes an unfinished recording, after a confirmation.")
                }
                Button(role: .cancel) {
                    model.notNow()
                } label: {
                    Text("Not now", comment: "Leaves an unfinished recording for the next launch.")
                }
            } message: { take in
                Text(
                    "Echo Engine closed while recording. Your audio up to that point (\(DisplayFormat.duration(take.duration))) is saved.",
                    comment: "Message of the Recover recording alert; the duration saved, e.g. 12:47."
                )
            }
            .confirmationDialog(
                Text("Delete this recording?", comment: "Confirmation before deleting an unfinished recording."),
                isPresented: Binding(get: { model.deleting != nil }, set: { if !$0 { model.cancelDelete() } }),
                titleVisibility: .visible
            ) {
                Button(role: .destructive) {
                    model.confirmDelete()
                } label: {
                    Text("Delete recording", comment: "Confirms deleting an unfinished recording.")
                }
                Button("Cancel", role: .cancel) {
                    model.cancelDelete()
                }
            } message: {
                Text("It can’t be undone.")
            }
            .alert(
                Text("Can’t recover this recording", comment: "Alert title: an unfinished recording couldn't be made a project."),
                isPresented: Binding(get: { model.isShowingFailure }, set: { if !$0 { model.dismissFailure() } })
            ) {
                Button("OK") { model.dismissFailure() }
            } message: {
                Text(
                    "It stays saved, and Echo Engine offers it again the next time it opens.",
                    comment: "Message when recovering a recording failed."
                )
            }
    }
}
