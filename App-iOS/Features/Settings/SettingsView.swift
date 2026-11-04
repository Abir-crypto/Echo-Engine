import EchoCore
import SwiftUI
#if DEBUG
import EchoCoreFakes
#endif

/// Makes the screen's model once (it's pushed from Home).
struct SettingsScreen: View {
    @Environment(AppContainer.self) private var container
    @State private var model: SettingsModel?

    var body: some View {
        if let model {
            SettingsView(model: model)
        } else {
            Color.token(.ground)
                .ignoresSafeArea()
                .task { model = container.makeSettingsModel() }
        }
    }
}

/// Settings (SPEC § 14.2, mockup `Design/screens/Settings.dc.html`): Appearance, Tint, Presets, Privacy, Storage,
/// Acknowledgements and Version. Native back button and controls (SPEC § 18.1).
struct SettingsView: View {
    let model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section(Text("Appearance")) {
                    Picker(selection: Binding(get: { model.settings.appearance }, set: { model.settings.appearance = $0 })) {
                        Text("System", comment: "Appearance: follow the system.").tag(Appearance.system)
                        Text("Dark", comment: "Appearance.").tag(Appearance.dark)
                        Text("Light", comment: "Appearance.").tag(Appearance.light)
                    } label: {
                        Text("Appearance")
                    }
                    .pickerStyle(.segmented)
                }

                section(Text("Tint"), caption: Text("Used for buttons and processed audio.")) {
                    TintPicker(selection: Binding(get: { model.settings.tint }, set: { model.settings.tint = $0 }))
                }

                GroupedRows {
                    NavigationLink {
                        PresetsScreen()
                    } label: {
                        LinkRow(title: Text("Presets"))
                    }
                    .buttonStyle(.plain)
                }

                section(Text("Privacy"), caption: Text("Your audio never leaves your device.")) {
                    GroupedRows {
                        SettingToggle(
                            title: Text("Share usage analytics"),
                            isOn: Binding(get: { model.consent.sharesAnalytics }, set: { model.consent.sharesAnalytics = $0 })
                        )
                        RowSeparator()
                        SettingToggle(
                            title: Text("Share crash reports"),
                            isOn: Binding(get: { model.consent.sharesCrashReports }, set: { model.consent.sharesCrashReports = $0 })
                        )
                    }
                }

                section(Text("Storage"), caption: Text("Projects aren’t included in iCloud backup. Export anything you want to keep.")) {
                    GroupedRows {
                        HStack(spacing: 12) {
                            rowTitle(Text("Projects"))
                            Spacer(minLength: 8)
                            size(model.projectsBytes)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 56)
                        RowSeparator()
                        HStack(spacing: 12) {
                            rowTitle(Text("Render cache"))
                            Spacer(minLength: 8)
                            size(model.cacheBytes)
                            Button {
                                Task { await model.clearCache() }
                            } label: {
                                Text("Clear", comment: "Clears the render cache.")
                            }
                            .buttonStyle(.secondary)
                            .disabled(model.isClearing || model.cacheBytes == 0)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 56)
                    }
                }

                GroupedRows {
                    NavigationLink {
                        AcknowledgementsView()
                    } label: {
                        LinkRow(title: Text("Acknowledgements"))
                    }
                    .buttonStyle(.plain)
                    RowSeparator()
                    HStack {
                        rowTitle(Text("Version"))
                        Spacer()
                        Text(verbatim: model.version)
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.token(.textSecondary))
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color.token(.ground).ignoresSafeArea())
        .crashReportScreen("settings")
        .navigationTitle("Settings")
        .toolbarTitleDisplayMode(.inlineLarge)
        // The mockup has no tab bar here, like the editor.
        .toolbar(.hidden, for: .tabBar)
        .task { await model.load() }
        #if DEBUG
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                DebugMenu()
            }
        }
        #endif
    }

    private func section(_ title: Text, caption: Text? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.token(.textSecondary))
                .accessibilityAddTraits(.isHeader)
            content()
            if let caption {
                caption
                    .font(.footnote)
                    .foregroundStyle(.token(.textSecondary))
            }
        }
    }

    private func rowTitle(_ title: Text) -> some View {
        title
            .font(.body.weight(.semibold))
            .foregroundStyle(.token(.textPrimary))
    }

    @ViewBuilder
    private func size(_ bytes: Int64?) -> some View {
        if let bytes {
            Text(DisplayFormat.fileSize(bytes))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.token(.textValue))
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }
}

/// A grouped row that opens a screen: title and a chevron.
private struct LinkRow: View {
    let title: Text

    var body: some View {
        HStack {
            title
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
}

/// A switch row (mockup: 56 pt, `Success` when on).
private struct SettingToggle: View {
    let title: Text
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            title
                .font(.body.weight(.semibold))
                .foregroundStyle(.token(.textPrimary))
        }
        .tint(.token(.success))
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
    }
}

/// The six tints as swatches with their names; the chosen one ringed (mockup).
private struct TintPicker: View {
    @Binding var selection: AppTint

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTint.allCases, id: \.self) { tint in
                let isSelected = tint == selection
                Button {
                    selection = tint
                } label: {
                    VStack(spacing: 6) {
                        Circle()
                            .fill(tint.fill)
                            .frame(width: 40, height: 40)
                            .padding(3)
                            .overlay(Circle().strokeBorder(isSelected ? Color.token(.textPrimary) : .clear, lineWidth: 2))
                        tint.displayName
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isSelected ? .token(.textPrimary) : .token(.textSecondary))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 14)
        .background(.token(.surface), in: .rect(cornerRadius: 14))
    }
}

extension AppTint {
    var displayName: Text {
        switch self {
        case .amber: Text("Amber", comment: "Tint name.")
        case .teal: Text("Teal", comment: "Tint name.")
        case .violet: Text("Violet", comment: "Tint name.")
        case .green: Text("Green", comment: "Tint name.")
        case .rose: Text("Rose", comment: "Tint name.")
        case .blue: Text("Blue", comment: "Tint name.")
        }
    }
}

#if DEBUG
@MainActor
private func previewSettingsModel() -> SettingsModel {
    SettingsModel(
        settings: FakeAppSettingsStore(), consent: FakeConsentStore(analytics: true, crashReports: true),
        projects: FakeProjectRepository(projects: PreviewProjects.all()), renders: FakeRenderCache(),
        waveforms: FakeWaveformProvider(), version: "1.0 (1)"
    )
}

#Preview("Dark") {
    NavigationStack { SettingsView(model: previewSettingsModel()) }
        .preferredColorScheme(.dark)
}

#Preview("Light, XXL") {
    NavigationStack { SettingsView(model: previewSettingsModel()) }
        .dynamicTypeSize(.xxxLarge)
}
#endif
