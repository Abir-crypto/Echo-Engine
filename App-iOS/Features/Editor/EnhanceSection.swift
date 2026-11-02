import EchoCore
import SwiftUI

/// "Enhance": the AI stack as a numbered list in processing order (SPEC § 9, mockup `Editor.dc.html`). Tap a row to
/// hear the stack up to it, tap its strength to change it, swipe to remove, drag to reorder; "Add enhancement".
struct EnhanceSection: View {
    let model: EditorModel
    let onEditStrength: (Int) -> Void
    let onAdd: () -> Void
    let onApplyPreset: () -> Void
    let onSaveAsPreset: () -> Void

    @Environment(\.appTint) private var tint
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The list sizes itself to its rows: it sits inside the editor's scroll view and doesn't scroll on its own.
    @State private var listHeight: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            stackList
        }
    }

    private var stackList: some View {
        List {
            ForEach(Array(model.aiStack.enumerated()), id: \.element.id) { index, operation in
                stackRow(index, operation)
            }
            .onMove { source, destination in
                model.moveEnhancements(fromOffsets: source, toOffset: destination)
            }
            addRow
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.token(.surface))
                .listRowSeparator(.hidden, edges: .bottom)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 14 }
        }
        .listStyle(.plain)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 52)
        .frame(height: listHeight)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.height }) { _, height in
            if height > 0 { listHeight = height }
        }
        .clipShape(.rect(cornerRadius: 14))
    }

    private func stackRow(_ index: Int, _ operation: AIOperation) -> some View {
        row(index, operation)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.token(.surface))
            .listRowSeparatorTint(Color.token(.separator))
            .alignmentGuide(.listRowSeparatorLeading) { _ in 14 }
            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
            .moveDisabled(!model.canEdit)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if model.canEdit {
                    Button("Remove", role: .destructive) { model.removeEnhancement(at: index) }
                }
            }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    title
                    Spacer(minLength: 8)
                    caption
                }
                VStack(alignment: .leading, spacing: 2) {
                    title
                    caption
                }
            }
            presetMenu
        }
    }

    /// Presets live in the Enhance header menu (SPEC § 9).
    private var presetMenu: some View {
        Menu {
            Button("Apply preset…", systemImage: "square.stack", action: onApplyPreset)
            Button("Save as preset…", systemImage: "square.and.arrow.down", action: onSaveAsPreset)
            if model.canUpdateBasePreset, let preset = model.basePreset {
                Button("Update “\(preset.displayName)”", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await model.updateBasePreset() }
                }
                .disabled(!model.isModifiedFromBasePreset)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.token(.textValue))
                .frame(width: 36, height: 36)
                .background(.token(.surface), in: .circle)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel(Text("Presets"))
        .disabled(!model.canEdit)
    }

    private var title: some View {
        Text("Enhance")
            .font(.title3.bold())
            .foregroundStyle(.token(.textPrimary))
            .accessibilityAddTraits(.isHeader)
    }

    private var caption: some View {
        Text("Applied top to bottom")
            .font(.footnote)
            .foregroundStyle(.token(.textSecondary))
    }

    private func row(_ index: Int, _ operation: AIOperation) -> some View {
        let auditioned = model.auditionedStep
        let isAuditioned = auditioned == index
        let isSkipped = auditioned.map { index > $0 } ?? false
        let isRendering = model.renderingStep == index
        return HStack(spacing: 12) {
            Text(index + 1, format: .number)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(isAuditioned ? tint.on : tint.text)
                .frame(minWidth: 24, minHeight: 24)
                .background(isAuditioned ? tint.fill : tint.fill.opacity(0.16), in: Capsule())
            VStack(alignment: .leading, spacing: 3) {
                Text(operation.kind.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.token(.textPrimary))
                if model.showsAlreadyReducesNoise(at: index) {
                    Text("Already reduces noise")
                        .font(.caption)
                        .foregroundStyle(.token(.textSecondary))
                }
                if isRendering, let progress = model.renderProgress {
                    ProgressView(value: progress)
                        .tint(tint.fill)
                        .accessibilityLabel(Text("Applying"))
                }
                // At accessibility sizes the name gets the row's width and the strength moves under it.
                if typeSize.isAccessibilitySize {
                    strengthButton(index, operation)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize {
                strengthButton(index, operation)
            }
            // The mockup's two-line reorder handle; the row reorders with a long press anywhere.
            Image(systemName: "equal")
                .font(.body)
                .foregroundStyle(.token(.iconMuted))
                .frame(width: 32, height: 44)
                .accessibilityHidden(true)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .opacity(isSkipped ? 0.45 : 1)
        .onTapGesture { model.audition(step: index) }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Plays the enhancements up to this one."))
        .accessibilityAddTraits(isAuditioned ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Change strength")) { onEditStrength(index) }
        .accessibilityAction(named: Text("Move up")) {
            if index > 0 { model.moveEnhancements(fromOffsets: [index], toOffset: index - 1) }
        }
        .accessibilityAction(named: Text("Move down")) {
            if index < model.aiStack.count - 1 { model.moveEnhancements(fromOffsets: [index], toOffset: index + 2) }
        }
        .accessibilityAction(named: Text("Remove")) { model.removeEnhancement(at: index) }
    }

    @ViewBuilder
    private func strengthButton(_ index: Int, _ operation: AIOperation) -> some View {
        if operation.kind != .unknown {
            Button {
                onEditStrength(index)
            } label: {
                Text(DisplayFormat.percent(operation.strength))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.token(.textValue))
                    .frame(minWidth: 44, minHeight: 44, alignment: typeSize.isAccessibilitySize ? .leading : .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!model.canEdit)
            .accessibilityLabel(Text("Strength"))
            .accessibilityValue(Text(DisplayFormat.percent(operation.strength)))
        }
    }

    private var addRow: some View {
        Button(action: onAdd) {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle")
                    .font(.title3)
                    .accessibilityHidden(true)
                Text("Add enhancement")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(tint.text)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!model.canEdit || !EditorModel.offeredFeatures.contains(where: model.canAdd))
        .opacity(model.canEdit ? 1 : 0.5)
    }
}

#if DEBUG
#Preview("Enhance, dark") {
    let model = previewAdjustModel()
    model.changeAIStack { $0.append(AIOperation(kind: .clearVoice, strength: 0.8)) }
    return ScrollView {
        EnhanceSection(model: model, onEditStrength: { _ in }, onAdd: {}, onApplyPreset: {}, onSaveAsPreset: {})
            .padding(20)
    }
    .background(Color.token(.ground))
    .preferredColorScheme(.dark)
}

#Preview("Enhance, light, Arabic XXL") {
    ScrollView {
        EnhanceSection(model: previewAdjustModel(), onEditStrength: { _ in }, onAdd: {}, onApplyPreset: {}, onSaveAsPreset: {})
            .padding(20)
    }
    .background(Color.token(.ground))
    .preferredColorScheme(.light)
    .previewArabicXXL()
}
#endif
