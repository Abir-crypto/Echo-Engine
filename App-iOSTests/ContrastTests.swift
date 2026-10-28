@testable import EchoEngine
import Testing
import UIKit

/// Every text/background pairing must reach WCAG AA (4.5:1) in light and dark (SPEC § 17, § 18.2).
struct ContrastTests {
    enum Mode: CaseIterable {
        case light, dark

        var traits: UITraitCollection {
            UITraitCollection(userInterfaceStyle: self == .light ? .light : .dark)
        }
    }

    struct Pairing: CustomTestStringConvertible {
        let text: String
        let background: String

        var testDescription: String { "\(text) on \(background)" }
    }

    static let pairings: [Pairing] = {
        let neutralText = [ColorToken.textPrimary, .textSecondary, .textTertiary, .textValue, .warning]
        let surfaces = [ColorToken.ground, .surface]
        var pairings = neutralText.flatMap { text in
            surfaces.map { Pairing(text: text.rawValue, background: $0.rawValue) }
        }
        pairings.append(Pairing(text: ColorToken.textPrimary.rawValue, background: ColorToken.surfaceRaised.rawValue))
        pairings.append(Pairing(text: ColorToken.textSecondary.rawValue, background: ColorToken.surfaceSunken.rawValue))
        for tint in AppTint.allCases {
            pairings += surfaces.map { Pairing(text: tint.assetName(.text), background: $0.rawValue) }
            pairings.append(Pairing(text: tint.assetName(.on), background: tint.assetName(.fill)))
        }
        return pairings
    }()

    @Test(arguments: ColorToken.allCases)
    func tokenExistsInCatalog(_ token: ColorToken) {
        #expect(UIColor(named: token.rawValue, in: .main, compatibleWith: nil) != nil)
    }

    @Test(arguments: AppTint.allCases, AppTint.Role.allCases)
    func tintColorExistsInCatalog(_ tint: AppTint, _ role: AppTint.Role) {
        #expect(UIColor(named: tint.assetName(role), in: .main, compatibleWith: nil) != nil)
    }

    @Test(arguments: pairings, Mode.allCases)
    func textPairingMeetsAA(_ pairing: Pairing, _ mode: Mode) throws {
        let text = try #require(rgba(of: pairing.text, in: mode))
        let background = try #require(rgba(of: pairing.background, in: mode))
        try #require(text.alpha == 1 && background.alpha == 1, "opaque pairings only")
        let ratio = contrast(text, background)
        #expect(ratio >= 4.5, "\(pairing.testDescription) (\(mode)): \(ratio)")
    }

    /// Badge text sits on translucent `BadgeFill` over the thumbnail: the card surface or any waveform color.
    @Test(arguments: [ColorToken.textPrimary, .textValue], Mode.allCases)
    func badgeTextMeetsAAOverEveryBackdrop(_ text: ColorToken, _ mode: Mode) throws {
        let textColor = try #require(rgba(of: text.rawValue, in: mode))
        let fill = try #require(rgba(of: ColorToken.badgeFill.rawValue, in: mode))
        let backdrops = [ColorToken.surface.rawValue, ColorToken.waveformIdle.rawValue] + AppTint.allCases.map { $0.assetName(.wave) }
        for backdrop in backdrops {
            let behind = try #require(rgba(of: backdrop, in: mode))
            let ratio = contrast(textColor, fill.composited(over: behind))
            #expect(ratio >= 4.5, "\(text.rawValue) on BadgeFill over \(backdrop) (\(mode)): \(ratio)")
        }
    }

    private struct RGBA {
        var red, green, blue, alpha: Double

        /// Source-over compositing in display (sRGB) space.
        func composited(over background: RGBA) -> RGBA {
            func mix(_ top: Double, _ bottom: Double) -> Double { top * alpha + bottom * (1 - alpha) }
            return RGBA(red: mix(red, background.red), green: mix(green, background.green), blue: mix(blue, background.blue), alpha: 1)
        }

        /// WCAG 2.x relative luminance.
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
    }

    private func contrast(_ first: RGBA, _ second: RGBA) -> Double {
        (max(first.luminance, second.luminance) + 0.05) / (min(first.luminance, second.luminance) + 0.05)
    }

    private func rgba(of name: String, in mode: Mode) -> RGBA? {
        guard let color = UIColor(named: name, in: .main, compatibleWith: mode.traits)?
            .resolvedColor(with: mode.traits) else { return nil }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return RGBA(red: red, green: green, blue: blue, alpha: alpha)
    }
}
