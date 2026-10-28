#if DEBUG
import SwiftUI

/// Temporary appearance and tint switcher until the Settings screen exists (F13.T01).
/// Debug builds only, so its labels are verbatim and stay out of the String Catalog.
struct DebugAppearanceMenu: View {
    @AppStorage(AppSettingsKey.appearance) private var appearance = Appearance.default
    @AppStorage(AppSettingsKey.tint) private var tint = AppTint.default

    var body: some View {
        Menu {
            Picker(selection: $appearance) {
                ForEach(Appearance.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
            } label: {
                Text(verbatim: "Appearance")
            }
            Picker(selection: $tint) {
                ForEach(AppTint.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
            } label: {
                Text(verbatim: "Tint")
            }
        } label: {
            Image(systemName: "paintpalette")
                .accessibilityLabel(Text(verbatim: "Debug appearance"))
        }
    }
}
#endif
