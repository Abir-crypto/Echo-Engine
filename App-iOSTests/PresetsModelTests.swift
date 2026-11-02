import EchoCore
import EchoCoreFakes
@testable import EchoEngine
import Foundation
import Testing

@MainActor
struct PresetsModelTests {
    private let builtIn = Preset(
        id: BuiltInPresetID.singing, name: "Singing", aiStack: [], manual: ManualSettings(), outputLoudness: nil,
        isBuiltIn: true, createdAt: Date(timeIntervalSince1970: 0)
    )
    private let booth = Preset(name: "Booth", aiStack: [], manual: ManualSettings(), outputLoudness: .podcast, createdAt: Date(timeIntervalSince1970: 0))
    private let car = Preset(name: "Car", aiStack: [], manual: ManualSettings(), outputLoudness: nil, createdAt: Date(timeIntervalSince1970: 0))

    @Test func builtInsAndTheirOwnPresetsAreListedApart() async {
        let model = PresetsModel(repository: FakePresetRepository(builtIns: [builtIn], saved: [car, booth]))

        await model.load()

        #expect(model.builtIns.map(\.id) == [builtIn.id])
        #expect(model.userPresets.map(\.name) == ["Booth", "Car"])
    }

    @Test func renamingKeepsTheNameTidy() async {
        let repository = FakePresetRepository(saved: [booth])
        let model = PresetsModel(repository: repository)
        await model.load()

        await model.rename(booth.id, to: "  Vocal booth ")
        #expect(model.userPresets.map(\.name) == ["Vocal booth"])

        await model.rename(booth.id, to: "   ")
        #expect(model.userPresets.map(\.name) == ["Vocal booth"], "empty names are ignored")
    }

    @Test func deletingRemovesIt() async {
        let repository = FakePresetRepository(saved: [booth, car])
        let model = PresetsModel(repository: repository)
        await model.load()

        await model.delete(booth.id)

        #expect(model.userPresets.map(\.name) == ["Car"])
        #expect(await repository.saved[booth.id] == nil)
    }

    @Test func failuresAreReported() async {
        let repository = FakePresetRepository(saved: [booth])
        let model = PresetsModel(repository: repository)
        await model.load()
        await repository.setError(CocoaError(.fileWriteOutOfSpace))

        await model.rename(booth.id, to: "Vocal booth")
        #expect(model.failure == .rename)

        await model.delete(booth.id)
        #expect(model.failure == .delete)
        #expect(model.userPresets.map(\.name) == ["Booth"])
    }
}
