import EchoCore
import SwiftUI

/// Dim mode (SPEC § 13.1; designed natively, user decision): a minimal dark screen with the status, the timer and the
/// meters, for long takes. Always dark; a tap anywhere goes back.
struct DimRecordingView: View {
    let model: RecordModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 6) {
                RecordingStatus(state: model.state, hasTake: model.hasTake)
                RecordingTimer(engine: model.engine)
            }
            ChannelMeters(model: model)
                .opacity(0.8)
            Spacer()
            Text("Tap to return", comment: "Hint at the bottom of the dim recording screen.")
                .font(.footnote)
                .foregroundStyle(.token(.textSecondary))
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.token(.ground).ignoresSafeArea())
        .contentShape(.rect)
        .onTapGesture { model.isDimmed = false }
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .accessibilityAction(named: Text("Return", comment: "VoiceOver action: leaves the dim recording screen.")) {
            model.isDimmed = false
        }
    }
}

#if DEBUG
#Preview {
    let model = previewRecordModel()
    DimRecordingView(model: model)
        .task {
            await model.appear()
            await model.record()
        }
}
#endif
