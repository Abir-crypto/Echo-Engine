import SwiftUI

/// Tab shell (SPEC § 14.1). Appearance and tint are applied by `EchoEngineApp`.
struct RootView: View {
    var body: some View {
        TabView {
            Tab("Projects", systemImage: "square.grid.2x2") {
                HomeView()
            }
            Tab("Record", systemImage: "mic") {
                RecordView()
            }
        }
    }
}

#Preview("Dark") {
    RootView()
        .tint(AppTint.default.text)
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    RootView()
        .tint(AppTint.default.text)
        .preferredColorScheme(.light)
}

#Preview("Arabic RTL, XXL") {
    RootView()
        .tint(AppTint.default.text)
        .environment(\.locale, Locale(identifier: "ar"))
        .environment(\.layoutDirection, .rightToLeft)
        .dynamicTypeSize(.xxxLarge)
}
