import EchoCore
import Foundation
import Observation

/// Offers takes the app was killed during, at launch (SPEC § 13.3, user decision): Recover makes a recorded project and
/// opens it, Delete removes it after a confirmation, Not now asks again at the next launch. Several are offered one
/// after another, oldest first.
@MainActor
@Observable
final class RecordingRecoveryModel {
    /// The take the "Recover recording?" alert offers.
    private(set) var offered: UnfinishedTake?
    /// The take the delete confirmation asks about.
    private(set) var deleting: UnfinishedTake?
    /// Recovering failed; the take stays and is offered again at the next launch.
    private(set) var isShowingFailure = false
    /// A recovered project to open in the Editor.
    private(set) var recoveredProjectID: UUID?

    @ObservationIgnored private let recovery: any RecordingRecovering
    @ObservationIgnored private let title: (Date) -> String
    @ObservationIgnored private var queue: [UnfinishedTake] = []
    /// The recovery or deletion in progress (tests wait for it).
    @ObservationIgnored private(set) var work: Task<Void, Never>?

    /// `title` makes the default title from the time the take started (SPEC § 5.4).
    init(recovery: any RecordingRecovering, title: @escaping (Date) -> String) {
        self.recovery = recovery
        self.title = title
    }

    func check() async {
        queue = await recovery.unfinishedTakes()
        showNext()
    }

    func recover() {
        guard let take = offered else { return }
        offered = nil
        work = Task {
            do {
                recoveredProjectID = try await recovery.recover(take, title: title(take.session.startedAt)).id
            } catch {
                isShowingFailure = true
            }
            showNext()
        }
    }

    func askToDelete() {
        guard let take = offered else { return }
        offered = nil
        deleting = take
    }

    func confirmDelete() {
        guard let take = deleting else { return }
        deleting = nil
        work = Task {
            // A failed delete leaves the take; it is offered again at the next launch.
            try? await recovery.delete(take)
            showNext()
        }
    }

    /// Back to the offer.
    func cancelDelete() {
        guard let take = deleting else { return }
        deleting = nil
        offered = take
    }

    func notNow() {
        guard offered != nil else { return }
        offered = nil
        showNext()
    }

    func dismissFailure() {
        isShowingFailure = false
        showNext()
    }

    func didOpenRecoveredProject() {
        recoveredProjectID = nil
    }

    private func showNext() {
        guard offered == nil, deleting == nil, !isShowingFailure, !queue.isEmpty else { return }
        offered = queue.removeFirst()
    }
}
