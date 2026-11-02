import EchoCore
@testable import EchoEngine
import Foundation
import Testing

@MainActor
struct BuiltInPresetsTests {
    private func bundled() throws -> [Preset] {
        try BuiltInPresets.load(from: try #require(AppContainer.builtInPresetsURL))
    }

    @Test func theBundledPresetsMatchTheSpec() throws {
        let presets = try bundled()
        #expect(presets.map(\.id) == [BuiltInPresetID.podcastVoice, BuiltInPresetID.outdoorVideo, BuiltInPresetID.singing])
        #expect(presets.allSatisfy { $0.isBuiltIn })

        let podcast = presets[0]
        #expect(podcast.aiStack.map(\.kind) == [.noiseSuppression, .voiceLeveler])
        #expect(podcast.aiStack.map(\.strength) == [0.7, 1.0])
        #expect(podcast.outputLoudness == .podcast)
        #expect(podcast.manual == ManualSettings())

        let outdoor = presets[1]
        #expect(outdoor.aiStack.map(\.kind) == [.noiseSuppression, .clearVoice])
        #expect(outdoor.aiStack.map(\.strength) == [0.9, 0.8])
        #expect(outdoor.outputLoudness == .youtube)

        let singing = presets[2]
        #expect(singing.aiStack.map(\.kind) == [.noiseSuppression])
        #expect(singing.aiStack.map(\.strength) == [0.4])
        #expect(singing.outputLoudness == nil)
        #expect(singing.manual.compressor.isEnabled)
        #expect(singing.manual.compressor.ratio == 2, "gentle")
        #expect(singing.manual.reverb.isEnabled)
        #expect(singing.manual.reverb.mix == 0.15)
    }

    @Test func builtInsShowLocalizedNamesAndUserPresetsTheirOwn() throws {
        let presets = try bundled()
        #expect(presets.map(\.displayName) == ["Podcast Voice", "Outdoor Video", "Singing"])
        let mine = Preset(name: "Booth", aiStack: [], manual: ManualSettings(), outputLoudness: nil, createdAt: .now)
        #expect(mine.displayName == "Booth")
    }

    @Test func theContainerOffersTheBuiltIns() async throws {
        let listed = try await AppContainer().presets.list()
        #expect(Array(listed.prefix(3).map(\.id)) == [BuiltInPresetID.podcastVoice, BuiltInPresetID.outdoorVideo, BuiltInPresetID.singing])
    }
}
