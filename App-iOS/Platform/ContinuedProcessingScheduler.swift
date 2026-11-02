import BackgroundTasks
import EchoCore
import Foundation

/// `BGContinuedProcessingTask` behind `BackgroundProcessing` (SPEC § 4.6, § 11.2 step 7): wraps the shared
/// `BGTaskScheduler`. One wildcard handler (`<bundle>.export.*`, listed in `BGTaskSchedulerPermittedIdentifiers`) is
/// registered on first use, which continued-processing tasks allow after launch; each export submits its own identifier.
@MainActor
final class ContinuedProcessingScheduler: BackgroundProcessing {
    static let identifierPrefix = (Bundle.main.bundleIdentifier ?? "akumatech.Echo-Engine") + ".export"

    private let scheduler: BGTaskScheduler
    private var isRegistered = false
    /// Activities waiting for the system to launch their task, by identifier.
    private var waiting: [String: ContinuedActivity] = [:]

    init(scheduler: BGTaskScheduler = .shared) {
        self.scheduler = scheduler
    }

    func begin(title: String, subtitle: String, onStop: @escaping @MainActor () -> Void) -> (any BackgroundActivity)? {
        if !isRegistered {
            isRegistered = scheduler.register(forTaskWithIdentifier: Self.identifierPrefix + ".*", using: .main) { [weak self] task in
                MainActor.assumeIsolated { self?.launched(task) }
            }
        }
        guard isRegistered else { return nil }
        let identifier = Self.identifierPrefix + "." + UUID().uuidString
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // Start now or not at all: a queued export would begin after the person already gave up on it.
        request.strategy = .fail
        do {
            try scheduler.submit(request)
        } catch {
            return nil
        }
        let activity = ContinuedActivity(onStop: onStop)
        waiting[identifier] = activity
        return activity
    }

    private func launched(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask, let activity = waiting.removeValue(forKey: task.identifier) else {
            task.setTaskCompleted(success: false)
            return
        }
        activity.attach(task)
    }
}

/// One export's task. Progress and the end can come before the system launches the task; they are applied then.
@MainActor
private final class ContinuedActivity: BackgroundActivity {
    private static let units: Int64 = 1_000

    private let onStop: @MainActor () -> Void
    private var task: BGContinuedProcessingTask?
    private var progress = 0.0
    private var result: Bool?

    init(onStop: @escaping @MainActor () -> Void) {
        self.onStop = onStop
    }

    func attach(_ task: BGContinuedProcessingTask) {
        if let result {
            task.setTaskCompleted(success: result)
            return
        }
        self.task = task
        task.progress.totalUnitCount = Self.units
        task.progress.completedUnitCount = Int64(progress * Double(Self.units))
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expired() }
        }
    }

    func report(progress: Double) {
        guard result == nil else { return }
        self.progress = min(max(progress, 0), 1)
        task?.progress.completedUnitCount = Int64(self.progress * Double(Self.units))
    }

    func finish(success: Bool) {
        guard result == nil else { return }
        result = success
        task?.setTaskCompleted(success: success)
        task = nil
    }

    /// The system, or the person in its progress UI, stopped the task.
    private func expired() {
        guard result == nil else { return }
        result = false
        task?.setTaskCompleted(success: false)
        task = nil
        onStop()
    }
}
