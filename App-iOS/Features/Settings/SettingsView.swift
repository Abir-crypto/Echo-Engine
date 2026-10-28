import SwiftUI

/// Settings. Placeholder until F13.T01; debug builds show the debug menu.
struct SettingsView: View {
    var body: some View {
        Color.token(.ground)
            .ignoresSafeArea()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            #if DEBUG
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    DebugMenu()
                }
            }
            #endif
    }
}
