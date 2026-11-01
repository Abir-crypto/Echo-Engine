import SwiftUI

/// The one primary action of a screen: Tint fill, `Tint-on` text, at least 54 pt tall, radius 16 (SPEC § 18.4).
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButton(configuration: configuration)
    }

    private struct PrimaryButton: View {
        let configuration: Configuration
        @Environment(\.appTint) private var tint
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(tint.on)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(tint.fill, in: .rect(cornerRadius: 16))
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
        }
    }
}

/// A secondary action: `Stroke` outline, `TextValue` text, capsule, at least 44 pt tall (SPEC § 18.4).
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.token(.textValue))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .overlay(Capsule().strokeBorder(.token(.stroke)))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

/// A primary action in a toolbar: Tint fill, `Tint-on` text, 40 pt capsule (Editor Export, SPEC § 9).
struct CompactPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CompactPrimaryButton(configuration: configuration)
    }

    private struct CompactPrimaryButton: View {
        let configuration: Configuration
        @Environment(\.appTint) private var tint
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint.on)
                .padding(.horizontal, 16)
                .frame(minHeight: 40)
                .background(tint.fill, in: Capsule())
                // A 40 pt capsule with a 44 pt touch target (SPEC § 17).
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
        }
    }
}

extension ButtonStyle where Self == CompactPrimaryButtonStyle {
    static var compactPrimary: CompactPrimaryButtonStyle { CompactPrimaryButtonStyle() }
}
