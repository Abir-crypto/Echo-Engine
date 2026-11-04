import EchoCore
import SwiftUI

extension View {
    /// Names the screen in crash reports when it shows (SPEC § 16). A fixed name, never content.
    func crashReportScreen(_ name: StaticString) -> some View {
        modifier(CrashReportScreen(name: "\(name)"))
    }
}

private struct CrashReportScreen: ViewModifier {
    let name: String
    /// Absent in previews.
    @Environment(AppContainer.self) private var container: AppContainer?

    func body(content: Content) -> some View {
        content.onAppear { container?.crashReporter.setContext(.screen, name) }
    }
}
