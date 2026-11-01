import EchoCore
import SwiftUI
#if DEBUG
import EchoCoreFakes
#endif

/// The detail sheets of the Adjust section (SPEC § 8, § 9).
enum AdjustSheet: String, Identifiable {
    case equalizer, gainDynamics, effects, loudness

    var id: Self { self }
}

/// "Adjust": Equalizer (mini curve), Gain and dynamics (input gain), Effects, Loudness (SPEC § 9). The mockup has no
/// Effects row; SPEC § 9 does.
struct AdjustSection: View {
    let model: EditorModel
    let onOpen: (AdjustSheet) -> Void

    @Environment(\.appTint) private var tint

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Adjust")
                .font(.title3.bold())
                .foregroundStyle(.token(.textPrimary))
                .accessibilityAddTraits(.isHeader)
            GroupedRows {
                row("Equalizer", value: isFlat ? Text("Flat") : Text("Adjusted"), sheet: .equalizer) {
                    EQCurveShape(bands: manual.eq)
                        .stroke(isFlat ? Color.token(.waveformIdle) : tint.fill, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 88, height: 28)
                        .environment(\.layoutDirection, .leftToRight)
                }
                RowSeparator()
                row("Gain and dynamics", value: Text(DisplayFormat.decibels(manual.inputGainDB)), sheet: .gainDynamics) {
                    valueText(DisplayFormat.decibels(manual.inputGainDB))
                }
                RowSeparator()
                row("Effects", value: effectsSummary, sheet: .effects) {
                    effectsSummary
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.token(.textValue))
                }
                RowSeparator()
                row("Loudness", value: loudnessValue, sheet: .loudness) {
                    loudnessValue
                        .font(.subheadline)
                        .foregroundStyle(.token(.textValue))
                }
            }
            .disabled(!model.canEdit)
            .opacity(model.canEdit ? 1 : 0.5)
        }
    }

    private var manual: ManualSettings { model.manual }
    private var isFlat: Bool { EQResponse.isFlat(manual.eq) }

    private var effectsSummary: Text {
        let isPitched = manual.pitchSemitones.rounded() != 0
        let pitch = DisplayFormat.semitones(manual.pitchSemitones)
        switch (isPitched, manual.reverb.isEnabled) {
        case (true, true): return Text("Pitch \(pitch) · Reverb")
        case (true, false): return Text("Pitch \(pitch)")
        case (false, true): return Text("Reverb")
        case (false, false): return Text("Off")
        }
    }

    private func row(
        _ title: LocalizedStringKey, value: Text, sheet: AdjustSheet, @ViewBuilder accessory: () -> some View
    ) -> some View {
        Button { onOpen(sheet) } label: {
            // At large text sizes the value moves under the title.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    rowTitle(title)
                    Spacer(minLength: 8)
                    accessory()
                    chevron
                }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        rowTitle(title)
                        accessory()
                    }
                    Spacer(minLength: 8)
                    chevron
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(value)
        .accessibilityAddTraits(.isButton)
    }

    private func rowTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.body.weight(.semibold))
            .foregroundStyle(.token(.textPrimary))
    }

    private var chevron: some View {
        Image(systemName: "chevron.forward")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.token(.iconMuted))
    }

    private func valueText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.token(.textValue))
    }

    /// The target's name, or Off.
    private var loudnessValue: Text {
        model.outputLoudness.map { Text($0.displayName) } ?? Text("Off")
    }
}

extension EditorModel {
    /// A slider binding into the manual chain; each step is heard at once.
    func binding(_ keyPath: WritableKeyPath<ManualSettings, Float>) -> Binding<Float> {
        Binding(get: { self.manual[keyPath: keyPath] }, set: { value in self.adjust { $0[keyPath: keyPath] = value } })
    }

    /// A switch binding into the manual chain; each flip is one undo step.
    func toggleBinding(_ keyPath: WritableKeyPath<ManualSettings, Bool>) -> Binding<Bool> {
        Binding(get: { self.manual[keyPath: keyPath] }, set: { value in
            self.adjust { $0[keyPath: keyPath] = value }
            self.finishAdjusting()
        })
    }
}

/// "Advanced" rows that open in place, sized like the other rows.
struct AdvancedDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { configuration.isExpanded.toggle() }
            } label: {
                HStack {
                    configuration.label
                        .font(.body)
                        .foregroundStyle(.token(.textPrimary))
                    Spacer()
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.token(.iconMuted))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? Text("Expanded") : Text("Collapsed"))
            if configuration.isExpanded {
                RowSeparator()
                configuration.content
            }
        }
    }
}

#if DEBUG
/// An editor model whose project has every Adjust control in use, for previews.
@MainActor
func previewAdjustModel(outputLoudness: LoudnessTarget? = nil) -> EditorModel {
    var project = PreviewProjects.all()[1]
    DebugManualDemo.apply(&project.clips[0].manual)
    project.outputLoudness = outputLoudness
    return EditorModel(
        stored: StoredProject(project: project, isReadOnly: false),
        engine: FakePlaybackEngine(duration: project.sourceInfo.duration),
        repository: FakeProjectRepository(projects: [project]),
        waveforms: FakeWaveformProvider(),
        devices: FakeAudioDeviceManager(),
        storage: FakeStorageEstimator(editBytes: 1_000, available: .max),
        entitlements: FakeEntitlements(),
        capabilities: FakeCapabilities(),
        renderer: FakeAIChainRenderer(),
        janitor: FakeRenderCacheJanitor(),
        autoLevel: FakeAutoLevelAnalyzer(),
        makeAutosaver: { _ in FakeProjectAutosaver() }
    )
}

extension View {
    /// Arabic, right to left, largest accessibility text (SPEC § 19).
    func previewArabicXXL() -> some View {
        environment(\.locale, Locale(identifier: "ar"))
            .environment(\.layoutDirection, .rightToLeft)
            .dynamicTypeSize(.accessibility3)
    }
}

#Preview("Adjust, dark") {
    AdjustSection(model: previewAdjustModel()) { _ in }
        .padding(20)
        .background(Color.token(.ground))
        .preferredColorScheme(.dark)
}

#Preview("Adjust, light, Arabic XXL") {
    ScrollView {
        AdjustSection(model: previewAdjustModel()) { _ in }
            .padding(20)
    }
    .background(Color.token(.ground))
    .preferredColorScheme(.light)
    .previewArabicXXL()
}
#endif
