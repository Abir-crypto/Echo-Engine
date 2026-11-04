import EchoCore
import SwiftUI
#if DEBUG
import EchoCoreFakes
#endif

/// First launch (SPEC § 16, § 18.5): the app, what it does, two consent switches (off until switched on), Continue.
/// Nothing is collected before Continue; Settings changes the answer later.
struct ConsentView: View {
    @Bindable var model: ConsentModel
    @Environment(\.appTint) private var tint

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "waveform")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(tint.on)
                        .frame(width: 72, height: 72)
                        .background(tint.fill, in: .rect(cornerRadius: 18))
                        .accessibilityHidden(true)
                    Text("Echo Engine", comment: "App name on the first-launch screen.")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.token(.textPrimary))
                        .accessibilityAddTraits(.isHeader)
                    Text("Clean, clear audio for your videos and recordings. Everything stays on your device.")
                        .font(.body)
                        .foregroundStyle(.token(.textSecondary))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Help improve Echo Engine")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.token(.textSecondary))
                        .accessibilityAddTraits(.isHeader)
                    GroupedRows {
                        ToggleRow(
                            title: "Share usage analytics",
                            caption: "Anonymous counts of the features you use. Never your audio or file names.",
                            isOn: $model.sharesAnalytics
                        )
                        RowSeparator()
                        ToggleRow(
                            title: "Share crash reports",
                            caption: "Technical details when the app crashes, so it can be fixed.",
                            isOn: $model.sharesCrashReports
                        )
                    }
                    Text("You can change these anytime in Settings.")
                        .font(.footnote)
                        .foregroundStyle(.token(.textSecondary))
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 48)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            Button {
                withAnimation { model.finish() }
            } label: {
                Text("Continue", comment: "Leaves the first-launch consent screen.")
            }
            .buttonStyle(.primary)
            .frame(maxWidth: 520)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background(Color.token(.ground))
        }
        .background(Color.token(.ground).ignoresSafeArea())
        .crashReportScreen("consent")
    }
}

#if DEBUG
@MainActor
private func previewConsent() -> ConsentView {
    let consent = FakeConsentStore()
    let analytics = FakeAnalytics()
    let telemetry = TelemetryConsent(consent: consent, analytics: analytics, crashes: FakeCrashReporter())
    return ConsentView(model: ConsentModel(consent: consent, telemetry: telemetry, analytics: analytics))
}

#Preview("Dark") {
    previewConsent()
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    previewConsent()
        .preferredColorScheme(.light)
}

#Preview("Arabic RTL, XXL") {
    previewConsent()
        .environment(\.locale, Locale(identifier: "ar"))
        .environment(\.layoutDirection, .rightToLeft)
        .dynamicTypeSize(.xxxLarge)
}
#endif
