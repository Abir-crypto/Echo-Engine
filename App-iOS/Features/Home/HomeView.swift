import SwiftUI

/// Projects tab. Placeholder until F02.T05.
struct HomeView: View {
    var body: some View {
        NavigationStack {
            Color.token(.ground)
                .ignoresSafeArea()
                .navigationTitle("Projects")
                #if DEBUG
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        DebugAppearanceMenu()
                    }
                }
                #endif
        }
    }
}

#Preview {
    HomeView()
}
