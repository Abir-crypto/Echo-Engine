/// Lets long work the person started keep running when the app goes to the background, with the system's progress
/// UI (SPEC § 4.6, § 11.2 step 7: `BGContinuedProcessingTask`).
@MainActor
public protocol BackgroundProcessing: AnyObject {
    /// Starts an activity shown as `title`/`subtitle`. `onStop` runs if the system or the person stops it before
    /// `finish`. `nil` when the system won't run it: the work then only runs while the app is open.
    func begin(title: String, subtitle: String, onStop: @escaping @MainActor () -> Void) -> (any BackgroundActivity)?
}

@MainActor
public protocol BackgroundActivity: AnyObject {
    /// 0…1; ignored once finished.
    func report(progress: Double)
    /// Ends the activity; later calls do nothing.
    func finish(success: Bool)
}
