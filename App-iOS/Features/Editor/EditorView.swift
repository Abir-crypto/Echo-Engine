import EchoCore
import SwiftUI

/// Editor. Placeholder until F04.T04: opening a project lands here.
struct EditorView: View {
    let project: Project

    var body: some View {
        Color.token(.ground)
            .ignoresSafeArea()
            .navigationTitle(project.title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
