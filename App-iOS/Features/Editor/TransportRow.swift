import SwiftUI

/// Hold for original, Play/Pause, Undo, Redo (SPEC § 9). Always left to right, like the other time controls (§ 17).
struct TransportRow: View {
    let isPlaying: Bool
    let canUndo: Bool
    let canRedo: Bool
    let onTogglePlay: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onHoldOriginal: (Bool) -> Void

    /// Resets when the touch ends or the system cancels it, so a cancelled hold never sticks.
    @GestureState private var isHolding = false

    var body: some View {
        HStack {
            holdForOriginal
            Spacer(minLength: 12)
            Button(action: onTogglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundStyle(.token(.ground))
                    .frame(width: 56, height: 56)
                    .background(.token(.textPrimary), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? Text("Pause") : Text("Play"))
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                circleButton("arrow.uturn.backward", label: Text("Undo"), isEnabled: canUndo, action: onUndo)
                    .keyboardShortcut("z", modifiers: .command)
                circleButton("arrow.uturn.forward", label: Text("Redo"), isEnabled: canRedo, action: onRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        // Glyphs live in fixed circles; past xxxLarge they would overflow them (SPEC § 17: no clipping at XXL).
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// Press and hold to hear the original; release to return (SPEC § 6.6).
    private var holdForOriginal: some View {
        Text("Hold for original")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.token(.textValue))
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(isHolding ? Color.token(.surface) : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(.token(.stroke)))
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isHolding) { _, isHolding, _ in isHolding = true }
            )
            .onChange(of: isHolding) { _, isHolding in onHoldOriginal(isHolding) }
            .accessibilityElement()
            .accessibilityLabel(Text("Hold for original"))
            .accessibilityHint(Text("Touch and hold to hear the original audio."))
            .accessibilityAddTraits(.isButton)
    }

    private func circleButton(_ symbol: String, label: Text, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(isEnabled ? Color.token(.textValue) : .token(.iconMuted))
                .frame(width: 40, height: 40)
                .background(.token(.surface), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}
