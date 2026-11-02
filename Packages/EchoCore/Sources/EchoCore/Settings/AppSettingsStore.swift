import Foundation
import Observation

/// User-selectable color scheme (SPEC § 14.2). The app maps it to SwiftUI.
public enum Appearance: String, CaseIterable, Sendable {
    case system, dark, light

    public static let `default` = Appearance.system
}

/// User-selectable tint; used for buttons and processed audio (SPEC § 14.2, § 18.2). The app maps it to colors.
public enum AppTint: String, CaseIterable, Codable, Sendable {
    case amber, teal, violet, green, rose, blue

    public static let `default` = AppTint.amber
}

/// App settings (SPEC § 4.3): appearance, tint and the last export choices per media type. Observable, so views
/// update when a setting changes.
@MainActor
public protocol AppSettingsStore: AnyObject, Observable {
    var appearance: Appearance { get set }
    var tint: AppTint { get set }
    /// The choices of the last export of this media type (SPEC § 11.1); `nil` before the first.
    func lastExportChoices(for mediaType: MediaType) -> ExportChoices?
    func setLastExportChoices(_ choices: ExportChoices, for mediaType: MediaType)
}

/// Settings in `UserDefaults`, under the keys `@AppStorage` used before, so earlier preferences carry over. Values
/// this version doesn't know read as the defaults.
@MainActor
@Observable
public final class UserDefaultsSettingsStore: AppSettingsStore {
    private static let appearanceKey = "settings.appearance"
    private static let tintKey = "settings.tint"

    @ObservationIgnored private let defaults: UserDefaults

    public var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    public var tint: AppTint {
        didSet { defaults.set(tint.rawValue, forKey: Self.tintKey) }
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Self.appearanceKey).flatMap(Appearance.init(rawValue:)) ?? .default
        tint = defaults.string(forKey: Self.tintKey).flatMap(AppTint.init(rawValue:)) ?? .default
    }

    public func lastExportChoices(for mediaType: MediaType) -> ExportChoices? {
        defaults.data(forKey: Self.exportKey(mediaType)).flatMap { try? JSONDecoder().decode(ExportChoices.self, from: $0) }
    }

    public func setLastExportChoices(_ choices: ExportChoices, for mediaType: MediaType) {
        guard let data = try? JSONEncoder().encode(choices) else { return }
        defaults.set(data, forKey: Self.exportKey(mediaType))
    }

    private static func exportKey(_ mediaType: MediaType) -> String {
        "settings.lastExport.\(mediaType.rawValue)"
    }
}
