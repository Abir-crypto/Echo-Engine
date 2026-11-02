import EchoCore
@testable import EchoEngine
import Foundation
import Testing

@MainActor
struct DeliveryPresenterTests {
    private let file = URL(filePath: "/tmp/Exports/a/Interview.m4a")

    /// Starts a delivery and waits until the presenter shows it.
    private func start(_ destination: InteractiveDestination, _ presenter: DeliveryPresenter) async -> Task<DeliveryOutcome, any Error> {
        let task = Task { try await destination.deliver(file) }
        while presenter.request == nil { await Task.yield() }
        return task
    }

    @Test(arguments: [DestinationKind.files, .share])
    func theRequestShowsUntilThePersonFinishes(_ kind: DestinationKind) async throws {
        let presenter = DeliveryPresenter()
        let task = await start(InteractiveDestination(kind: kind, presenter: presenter), presenter)

        #expect(presenter.request?.kind == kind)
        #expect(presenter.request?.file == file)
        presenter.finish(.delivered)

        #expect(try await task.value == .delivered)
        #expect(presenter.request == nil)
    }

    @Test func closingWithoutSavingIsACancel() async throws {
        let presenter = DeliveryPresenter()
        let task = await start(InteractiveDestination(kind: .files, presenter: presenter), presenter)

        presenter.finish(.cancelled)

        #expect(try await task.value == .cancelled)
    }

    @Test func aFailedSaveThrows() async throws {
        let presenter = DeliveryPresenter()
        let task = await start(InteractiveDestination(kind: .files, presenter: presenter), presenter)

        presenter.fail()

        await #expect(throws: ExportError.deliveryFailed) { try await task.value }
    }

    @Test func aNewerRequestClosesTheOlderOne() async throws {
        let presenter = DeliveryPresenter()
        let first = await start(InteractiveDestination(kind: .files, presenter: presenter), presenter)
        let firstID = presenter.request?.id

        let second = Task { try await InteractiveDestination(kind: .share, presenter: presenter).deliver(file) }
        while presenter.request?.id == firstID { await Task.yield() }

        #expect(try await first.value == .cancelled)
        #expect(presenter.request?.kind == .share)
        presenter.finish(.delivered)
        #expect(try await second.value == .delivered)
    }

    @Test func cancellingTheExportClosesTheRequest() async throws {
        let presenter = DeliveryPresenter()
        let task = await start(InteractiveDestination(kind: .share, presenter: presenter), presenter)

        task.cancel()

        #expect(try await task.value == .cancelled)
        while presenter.request != nil { await Task.yield() }
    }

    @Test func extraFinishesAreIgnored() async throws {
        let presenter = DeliveryPresenter()
        let task = await start(InteractiveDestination(kind: .share, presenter: presenter), presenter)

        presenter.finish(.delivered)
        presenter.finish(.cancelled)
        presenter.fail()

        #expect(try await task.value == .delivered)
    }
}
