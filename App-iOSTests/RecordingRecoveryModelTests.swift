import EchoCore
import EchoCoreFakes
import Foundation
@testable import EchoEngine
import Testing

@MainActor
struct RecordingRecoveryModelTests {
    private let first = UnfinishedTake(
        id: UUID(), session: TakeSession(startedAt: Date(timeIntervalSince1970: 1_800_000_000), channelNames: ["Host"]), duration: 767
    )
    private let second = UnfinishedTake(
        id: UUID(), session: TakeSession(startedAt: Date(timeIntervalSince1970: 1_800_000_600), channelNames: []), duration: 12
    )

    private func model(_ recovery: FakeRecordingRecovery) -> RecordingRecoveryModel {
        RecordingRecoveryModel(recovery: recovery, title: { "Recording at \($0.timeIntervalSince1970)" })
    }

    @Test func nothingToRecoverShowsNothing() async {
        let model = model(FakeRecordingRecovery())
        await model.check()
        #expect(model.offered == nil)
    }

    @Test func recoverMakesTheProjectToOpenThenOffersTheNextTake() async {
        let recovery = FakeRecordingRecovery(takes: [first, second])
        let model = model(recovery)
        await model.check()
        #expect(model.offered == first, "oldest first")

        model.recover()
        #expect(model.offered == nil)
        await model.work?.value
        #expect(model.recoveredProjectID == first.id)
        #expect(await recovery.recovered == [first.id])
        #expect(model.offered == second)
        model.didOpenRecoveredProject()
        #expect(model.recoveredProjectID == nil)
    }

    @Test func deleteAsksFirstAndCancelGoesBackToTheOffer() async {
        let recovery = FakeRecordingRecovery(takes: [first])
        let model = model(recovery)
        await model.check()
        model.askToDelete()
        #expect(model.offered == nil)
        #expect(model.deleting == first)
        model.cancelDelete()
        #expect(model.offered == first)
        #expect(model.deleting == nil)

        model.askToDelete()
        model.confirmDelete()
        model.cancelDelete()   // the dialog's dismissal after the button: changes nothing
        await model.work?.value
        #expect(await recovery.deleted == [first.id])
        #expect(model.offered == nil)
        #expect(model.deleting == nil)
    }

    @Test func notNowKeepsTheTakeForTheNextLaunch() async {
        let recovery = FakeRecordingRecovery(takes: [first])
        let model = model(recovery)
        await model.check()
        model.notNow()
        #expect(model.offered == nil)
        #expect(await recovery.takes == [first], "still there next time")
        #expect(await recovery.deleted.isEmpty)
    }

    @Test func aFailedRecoveryExplainsAndMovesOn() async {
        let model = model(FakeRecordingRecovery(takes: [first, second], recoverError: .cantCreateProject))
        await model.check()
        model.recover()
        await model.work?.value
        #expect(model.isShowingFailure)
        #expect(model.offered == nil, "one alert at a time")
        #expect(model.recoveredProjectID == nil)
        model.dismissFailure()
        #expect(model.offered == second)
    }

    @Test func theTitleIsTheRecordingTime() {
        let date = Date(timeIntervalSince1970: 1_793_202_120)   // 2026-10-28 15:42 UTC
        let utc = TimeZone(identifier: "UTC")!
        #expect(DisplayFormat.recordingTitle(date, timeZone: utc, locale: Locale(identifier: "en_GB")) == "Recording, 28 Oct 2026, 15:42")
        #expect(DisplayFormat.recordingTitle(date, timeZone: utc, locale: Locale(identifier: "en_US")) == "Recording, Oct 28, 2026, 3:42\u{202F}PM")
    }
}
