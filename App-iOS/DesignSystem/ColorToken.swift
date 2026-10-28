import SwiftUI

/// Color tokens from the asset catalog, each with light and dark variants (SPEC § 18.2).
/// Views use these (or `AppTint`) and never literal colors.
enum ColorToken: String, CaseIterable {
    case ground = "Ground"
    case surface = "Surface"
    case surfaceSunken = "SurfaceSunken"
    case surfaceRaised = "SurfaceRaised"
    case separator = "Separator"
    case stroke = "Stroke"
    case textPrimary = "TextPrimary"
    case textSecondary = "TextSecondary"
    case textTertiary = "TextTertiary"
    case iconMuted = "IconMuted"
    case waveformIdle = "WaveformIdle"
    case waveformOriginal = "WaveformOriginal"
    case playhead = "Playhead"
    case record = "Record"
    case clip = "Clip"
    case warning = "Warning"
    case success = "Success"
    case dim = "Dim"

    var color: Color { Color(rawValue) }
}

extension ShapeStyle where Self == Color {
    /// A color token as a style: `.foregroundStyle(.token(.textSecondary))`. One entry point instead of
    /// one static per token, because names like `separator` collide with SwiftUI's own styles.
    static func token(_ token: ColorToken) -> Color {
        token.color
    }
}
