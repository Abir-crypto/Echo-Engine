import AppIntents

/// Stop on the recording Live Activity (SPEC § 13.7). Live Activity intents run in the app's process, which ends the
/// take like the Record screen's Stop through the `RecordingStopRelay` it registered with `AppDependencyManager`.
struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = LocalizedStringResource(
        "Stop recording", comment: "Live Activity button and action: ends the recording."
    )
    static let isDiscoverable = false

    @AppDependency private var relay: RecordingStopRelay

    init() {}

    func perform() async throws -> some IntentResult {
        await relay.stop()
        return .result()
    }
}

/// Hands the Live Activity's Stop to whatever is recording: the Record screen's model sets `handler` while a take is
/// open. One instance, owned by the composition root and registered with `AppDependencyManager` at launch.
@MainActor
final class RecordingStopRelay {
    var handler: (@MainActor () async -> Void)?

    init() {}

    func stop() async {
        await handler?()
    }
}
