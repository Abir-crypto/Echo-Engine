import SwiftUI

/// Settings. The full screen comes in F13.T01 (mockup `Design/screens/Settings.dc.html`); for now it links to
/// Presets (SPEC § 14.2). Debug builds show the debug menu.
struct SettingsView: View {
    var body: some View {
        ScrollView {
            GroupedRows {
                NavigationLink {
                    PresetsScreen()
                } label: {
                    HStack {
                        Text("Presets")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.token(.textPrimary))
                        Spacer()
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.token(.iconMuted))
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color.token(.ground).ignoresSafeArea())
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
