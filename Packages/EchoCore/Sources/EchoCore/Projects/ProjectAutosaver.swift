import Foundation

/// Saves project changes without a Save button (SPEC § 5.3).
public protocol ProjectAutosaving: Sendable {
    /// Records the latest state; it is saved once no further change arrives for the debounce delay.
    func schedule(_ project: Project) async
    /// Saves the pending change now and returns once every scheduled save is on disk. Call when the scene
    /// leaves `.active` and when leaving the editor.
    func flush() async
}

/// Debounced autosave: each change restarts the delay and the latest change wins. Saves run in order, one at a
/// time. Failures go to `onError` and are not retried; every save writes the whole project, so the next change
/// saves everything.
public actor ProjectAutosaver: ProjectAutosaving {
    private let repository: any ProjectRepository
    private let delay: Duration
    private let clock: any Clock<Duration>
    private let dateProvider: any DateProviding
    private let onError: @Sendable (any Error) -> Void

    private var pending: Project?
    private var timer: Task<Void, Never>?
    private var lastSave: Task<Void, Never>?

    public init(
        repository: any ProjectRepository,
        delay: Duration = .seconds(1),
        clock: any Clock<Duration> = ContinuousClock(),
        dateProvider: any DateProviding = SystemClock(),
        onError: @escaping @Sendable (any Error) -> Void
    ) {
        self.repository = repository
        self.delay = delay
        self.clock = clock
        self.dateProvider = dateProvider
        self.onError = onError
    }

    public func schedule(_ project: Project) {
        var project = project
        project.updatedAt = dateProvider.now
        pending = project
        timer?.cancel()
        timer = Task { [clock, delay] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            await self.flush()
        }
    }

    public func flush() async {
        timer?.cancel()
        timer = nil
        if let project = pending {
            pending = nil
            let previous = lastSave
            lastSave = Task { [repository, onError] in
                await previous?.value
                do {
                    try await repository.save(project)
                } catch {
                    onError(error)
                }
            }
        }
        await lastSave?.value
    }
}
