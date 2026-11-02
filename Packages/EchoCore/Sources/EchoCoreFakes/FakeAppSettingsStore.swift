import EchoCore
import Observation

/// In-memory settings for tests and previews.
@MainActor
@Observable
public final class FakeAppSettingsStore: AppSettingsStore {
    public var appearance: Appearance
    public var tint: AppTint
    public private(set) var exportChoices: [MediaType: ExportChoices] = [:]

    public init(appearance: Appearance = .default, tint: AppTint = .default) {
        self.appearance = appearance
        self.tint = tint
    }

    public func lastExportChoices(for mediaType: MediaType) -> ExportChoices? {
        exportChoices[mediaType]
    }

    public func setLastExportChoices(_ choices: ExportChoices, for mediaType: MediaType) {
        exportChoices[mediaType] = choices
    }
}
