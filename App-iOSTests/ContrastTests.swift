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
        let neutralText = [ColorToken.textPrimary, .textSecondary, .textTertiary, .warning]
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
        let text = try #require(luminance(of: pairing.text, in: mode))
        let background = try #require(luminance(of: pairing.background, in: mode))
        let ratio = (max(text, background) + 0.05) / (min(text, background) + 0.05)
        #expect(ratio >= 4.5, "\(pairing.testDescription) (\(mode)): \(ratio)")
    }

    /// WCAG 2.x relative luminance of an opaque catalog color.
    private func luminance(of name: String, in mode: Mode) -> Double? {
        guard let color = UIColor(named: name, in: .main, compatibleWith: mode.traits)?
            .resolvedColor(with: mode.traits) else { return nil }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha), alpha == 1 else { return nil }
        func linear(_ channel: CGFloat) -> Double {
            let c = Double(channel)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
