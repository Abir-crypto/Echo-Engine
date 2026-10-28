import SwiftUI

/// User-selectable color scheme (SPEC § 14.2).
enum Appearance: String, CaseIterable {
    case system, dark, light

    static let `default` = Appearance.system

    /// `nil` follows the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}
