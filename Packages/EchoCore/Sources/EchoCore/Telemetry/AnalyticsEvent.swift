/// The product events (SPEC § 16). Never user content: no titles, file names, paths or audio; durations as buckets.
public enum AnalyticsEvent: Equatable, Sendable {
    case onboardingCompleted(analytics: Bool, crash: Bool)
    case importStarted(mediaType: MediaType)
    case importCompleted(mediaType: MediaType, durationBucket: DurationBucket)
    case importFailed(reason: ImportFailureReason)
    case aiFeatureApplied(AIFeature, stackPosition: Int)
    case aiFeatureRemoved(AIFeature)
    case undoUsed, redoUsed, originalComparedHeld
    case manualControlOpened(ManualGroup)
    case loudnessTargetSet(LoudnessTargetKind)
    case presetApplied(isBuiltIn: Bool), presetSaved
    case exportStarted(output: ExportKind, format: AudioFormat?)
    case exportCompleted(output: ExportKind, format: AudioFormat?, destination: DestinationKind, postAction: PostExportAction)
    case exportFailed(reason: ExportFailureReason)
    case recordingStarted(inputType: InputType, channels: Int, suppression: SuppressionLevel, autoTune: Bool, backingTrack: Bool)
    case recordingFinished(durationBucket: DurationBucket, interrupted: Bool)
    case storageBlocked(stage: StorageStage)

    /// The event's name as analytics receives it.
    public var name: String {
        switch self {
        case .onboardingCompleted: "onboarding_completed"
        case .importStarted: "import_started"
        case .importCompleted: "import_completed"
        case .importFailed: "import_failed"
        case .aiFeatureApplied: "ai_feature_applied"
        case .aiFeatureRemoved: "ai_feature_removed"
        case .undoUsed: "undo_used"
        case .redoUsed: "redo_used"
        case .originalComparedHeld: "original_compared_held"
        case .manualControlOpened: "manual_control_opened"
        case .loudnessTargetSet: "loudness_target_set"
        case .presetApplied: "preset_applied"
        case .presetSaved: "preset_saved"
        case .exportStarted: "export_started"
        case .exportCompleted: "export_completed"
        case .exportFailed: "export_failed"
        case .recordingStarted: "recording_started"
        case .recordingFinished: "recording_finished"
        case .storageBlocked: "storage_blocked"
        }
    }

    /// Its parameters: names, kinds and counts only.
    public var parameters: [String: AnalyticsValue] {
        switch self {
        case let .onboardingCompleted(analytics, crash):
            ["analytics": .bool(analytics), "crash_reports": .bool(crash)]
        case let .importStarted(mediaType):
            ["media_type": .string(mediaType.rawValue)]
        case let .importCompleted(mediaType, bucket):
            ["media_type": .string(mediaType.rawValue), "duration_bucket": .string(bucket.rawValue)]
        case let .importFailed(reason):
            ["reason": .string(reason.rawValue)]
        case let .aiFeatureApplied(feature, position):
            ["feature": .string(feature.rawValue), "stack_position": .int(position)]
        case let .aiFeatureRemoved(feature):
            ["feature": .string(feature.rawValue)]
        case .undoUsed, .redoUsed, .originalComparedHeld, .presetSaved:
            [:]
        case let .manualControlOpened(group):
            ["group": .string(group.rawValue)]
        case let .loudnessTargetSet(kind):
            ["target": .string(kind.rawValue)]
        case let .presetApplied(isBuiltIn):
            ["is_built_in": .bool(isBuiltIn)]
        case let .exportStarted(output, format):
            Self.export(output: output, format: format)
        case let .exportCompleted(output, format, destination, postAction):
            Self.export(output: output, format: format).merging(
                ["destination": .string(destination.rawValue), "post_action": .string(postAction.rawValue)]
            ) { $1 }
        case let .exportFailed(reason):
            ["reason": .string(reason.rawValue)]
        case let .recordingStarted(inputType, channels, suppression, autoTune, backingTrack):
            [
                "input_type": .string(inputType.rawValue), "channels": .int(channels), "suppression": .string(suppression.rawValue),
                "auto_tune": .bool(autoTune), "backing_track": .bool(backingTrack),
            ]
        case let .recordingFinished(bucket, interrupted):
            ["duration_bucket": .string(bucket.rawValue), "interrupted": .bool(interrupted)]
        case let .storageBlocked(stage):
            ["stage": .string(stage.rawValue)]
        }
    }

    private static func export(output: ExportKind, format: AudioFormat?) -> [String: AnalyticsValue] {
        var parameters: [String: AnalyticsValue] = ["output": .string(output.rawValue)]
        if let format { parameters["format"] = .string(format.rawValue) }
        return parameters
    }
}

/// A parameter value analytics accepts.
public enum AnalyticsValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
}

/// Durations are only ever sent as one of these (SPEC § 16).
public enum DurationBucket: String, Sendable {
    case underOneMinute = "<1m"
    case oneToTenMinutes = "1-10m"
    case tenToSixtyMinutes = "10-60m"
    case overSixtyMinutes = ">60m"

    public init(seconds: Double) {
        switch seconds {
        case ..<60: self = .underOneMinute
        case ..<600: self = .oneToTenMinutes
        case ..<3_600: self = .tenToSixtyMinutes
        default: self = .overSixtyMinutes
        }
    }
}

public enum ImportFailureReason: String, Sendable {
    case unsupportedFormat, noAudio, unreadable, notEnoughSpace, other

    public init(_ error: any Error) {
        switch error as? ImportError {
        case .unsupportedFormat?: self = .unsupportedFormat
        case .noAudio?: self = .noAudio
        case .unreadable?: self = .unreadable
        case nil: self = .other
        }
    }
}

/// The Adjust groups (SPEC § 8).
public enum ManualGroup: String, Sendable {
    case equalizer, gainDynamics, effects, loudness
}

/// A loudness target without its number (Custom's LUFS is a choice of the person, but harmless; kept to the kind).
public enum LoudnessTargetKind: String, Sendable {
    case off, youtube, instagram, tiktok, spotify, podcast, appleMusic, custom

    public init(_ target: LoudnessTarget?) {
        switch target {
        case nil: self = .off
        case .youtube?: self = .youtube
        case .instagram?: self = .instagram
        case .tiktok?: self = .tiktok
        case .spotify?: self = .spotify
        case .podcast?: self = .podcast
        case .appleMusic?: self = .appleMusic
        case .custom?, .unknown?: self = .custom
        }
    }
}

public enum ExportFailureReason: String, Sendable {
    case notEnoughSpace, renderFailed, encodingFailed, videoFailed, deliveryFailed, stopped, other
}

/// The kind of input recorded from (SPEC § 13.2).
public enum InputType: String, Sendable {
    case builtInMic, headsetMic, usb, bluetooth, other

    public init(_ kind: AudioInput.Kind) {
        switch kind {
        case .builtInMic: self = .builtInMic
        case .headsetMic: self = .headsetMic
        case .usb: self = .usb
        case .bluetooth: self = .bluetooth
        case .other: self = .other
        }
    }
}

/// Where free space ran out (SPEC § 15).
public enum StorageStage: String, Sendable {
    case `import`, edit, export, recording
}
