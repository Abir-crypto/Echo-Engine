import EchoCore
import SwiftUI

extension Appearance {
    /// `nil` follows the system setting (SPEC § 14.2).
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}
