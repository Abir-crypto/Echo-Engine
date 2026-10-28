import SwiftUI

/// User-selectable tint; used for buttons and processed audio (SPEC § 14.2, § 18.2).
enum AppTint: String, CaseIterable, Codable {
    case amber, teal, violet, green, rose, blue

    static let `default` = AppTint.amber
}

extension AppTint {
    /// Asset catalog color roles. Asset name: `Tint/<tint><suffix>`.
    enum Role: String, CaseIterable {
        case fill = ""
        case text = "-text"
        case wave = "-wave"
        case on = "-on"
    }

    func assetName(_ role: Role) -> String {
        "Tint/\(rawValue)\(role.rawValue)"
    }

    /// Fill for primary buttons and active states.
    var fill: Color { Color(assetName(.fill)) }
    /// Text and icons on `Ground`.
    var text: Color { Color(assetName(.text)) }
    /// Processed waveform.
    var wave: Color { Color(assetName(.wave)) }
    /// Text on a `fill` background.
    var on: Color { Color(assetName(.on)) }
}
