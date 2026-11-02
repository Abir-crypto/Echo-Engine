import EchoCore
import Foundation
import Testing

@MainActor
final class AppSettingsStoreTests {
    private let suiteName = "AppSettingsStoreTests-\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    @Test func startsWithTheSpecDefaults() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        #expect(store.appearance == .system)
        #expect(store.tint == .amber)
        #expect(store.lastExportChoices(for: .video) == nil)
        #expect(store.lastExportChoices(for: .audio) == nil)
    }

    @Test func changesAreKeptForTheNextLaunch() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.appearance = .dark
        store.tint = .teal

        let relaunched = UserDefaultsSettingsStore(defaults: defaults)
        #expect(relaunched.appearance == .dark)
        #expect(relaunched.tint == .teal)
    }

    @Test func preferencesSavedByEarlierBuildsAreRead() {
        // Before this store, `@AppStorage` saved the raw values under these keys.
        defaults.set("light", forKey: "settings.appearance")
        defaults.set("rose", forKey: "settings.tint")

        let store = UserDefaultsSettingsStore(defaults: defaults)
        #expect(store.appearance == .light)
        #expect(store.tint == .rose)
    }

    @Test func unknownStoredValuesFallBackToTheDefaults() {
        defaults.set("sepia", forKey: "settings.appearance")
        defaults.set("neon", forKey: "settings.tint")

        let store = UserDefaultsSettingsStore(defaults: defaults)
        #expect(store.appearance == .system)
        #expect(store.tint == .amber)
    }

    @Test func lastExportChoicesAreKeptPerMediaType() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        var video = ExportChoices.defaults(for: .video)
        video.kind = .both
        video.quality = .lossless
        var audio = ExportChoices.defaults(for: .audio)
        audio.quality = .custom
        audio.custom = AudioExportSettings(format: .wav, sampleRate: 44_100, bitDepth: 16, bitrate: nil)
        audio.destination = .share

        store.setLastExportChoices(video, for: .video)
        store.setLastExportChoices(audio, for: .audio)

        let relaunched = UserDefaultsSettingsStore(defaults: defaults)
        #expect(relaunched.lastExportChoices(for: .video) == video)
        #expect(relaunched.lastExportChoices(for: .audio) == audio)
    }

    @Test func unreadableExportChoicesAreIgnored() {
        defaults.set(Data("{\"kind\":\"hologram\"}".utf8), forKey: "settings.lastExport.video")
        #expect(UserDefaultsSettingsStore(defaults: defaults).lastExportChoices(for: .video) == nil)
    }
}

struct ExportChoicesTests {
    @Test func videoProjectsStartAsTheMockupShows() {
        let choices = ExportChoices.defaults(for: .video)
        #expect(choices.kind == .video)
        #expect(choices.quality == .high)
        #expect(choices.destination == .photos)
        #expect(choices.custom == AudioExportSettings(format: .aac, sampleRate: 48_000, bitDepth: nil, bitrate: 256_000))
    }

    @Test func audioProjectsExportAudioToFiles() {
        let choices = ExportChoices.defaults(for: .audio)
        #expect(choices.kind == .audioOnly)
        #expect(choices.quality == .high)
        #expect(choices.destination == .files)
    }
}
