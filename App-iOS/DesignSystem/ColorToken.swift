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
    static var ground: Color { ColorToken.ground.color }
    static var surface: Color { ColorToken.surface.color }
    static var surfaceSunken: Color { ColorToken.surfaceSunken.color }
    static var surfaceRaised: Color { ColorToken.surfaceRaised.color }
    static var separator: Color { ColorToken.separator.color }
    static var stroke: Color { ColorToken.stroke.color }
    static var textPrimary: Color { ColorToken.textPrimary.color }
    static var textSecondary: Color { ColorToken.textSecondary.color }
    static var textTertiary: Color { ColorToken.textTertiary.color }
    static var iconMuted: Color { ColorToken.iconMuted.color }
    static var waveformIdle: Color { ColorToken.waveformIdle.color }
    static var waveformOriginal: Color { ColorToken.waveformOriginal.color }
    static var playhead: Color { ColorToken.playhead.color }
    static var record: Color { ColorToken.record.color }
    static var clip: Color { ColorToken.clip.color }
    static var warning: Color { ColorToken.warning.color }
    static var success: Color { ColorToken.success.color }
    static var dim: Color { ColorToken.dim.color }
}
