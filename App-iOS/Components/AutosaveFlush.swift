import EchoCore
import SwiftUI

extension View {
    /// Flushes pending autosave when the scene leaves `.active` and when this view disappears, for example when
    /// leaving the editor (SPEC § 5.3).
    func flushesAutosave(_ autosaver: any ProjectAutosaving) -> some View {
        modifier(AutosaveFlush(autosaver: autosaver))
    }
}

private struct AutosaveFlush: ViewModifier {
    let autosaver: any ProjectAutosaving
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { flush() }
            }
            .onDisappear(perform: flush)
    }

    private func flush() {
        Task { await autosaver.flush() }
    }
}
