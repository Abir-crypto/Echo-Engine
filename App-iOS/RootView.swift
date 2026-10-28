import SwiftUI

/// Tab shell with the user's appearance and tint applied (SPEC § 14).
struct RootView: View {
    @AppStorage(AppSettingsKey.appearance) private var appearance = Appearance.default
    @AppStorage(AppSettingsKey.tint) private var tint = AppTint.default

    var body: some View {
        TabView {
            Tab("Projects", systemImage: "square.grid.2x2") {
                HomeView()
            }
            Tab("Record", systemImage: "mic") {
                RecordView()
            }
        }
        // System-tinted controls are mostly text and icons on Ground, so they use the text role.
        .tint(tint.text)
        .preferredColorScheme(appearance.colorScheme)
    }
}

#Preview("Dark") {
    RootView()
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    RootView()
        .preferredColorScheme(.light)
}

#Preview("Arabic RTL, XXL") {
    RootView()
        .environment(\.locale, Locale(identifier: "ar"))
        .environment(\.layoutDirection, .rightToLeft)
        .dynamicTypeSize(.xxxLarge)
}
