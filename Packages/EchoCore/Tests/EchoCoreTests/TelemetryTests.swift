import EchoCore
import EchoCoreFakes
import Testing

/// SPEC § 16: typed events, no user content, durations as buckets.
struct TelemetryTests {
    @Test func durationsAreOnlySentAsBuckets() {
        #expect(DurationBucket(seconds: 59).rawValue == "<1m")
        #expect(DurationBucket(seconds: 60).rawValue == "1-10m")
        #expect(DurationBucket(seconds: 599).rawValue == "1-10m")
        #expect(DurationBucket(seconds: 600).rawValue == "10-60m")
        #expect(DurationBucket(seconds: 3_600).rawValue == ">60m")
    }

    @Test func eventsCarryKindsAndCountsOnly() {
        let event = AnalyticsEvent.recordingStarted(inputType: .usb, channels: 2, suppression: .high, autoTune: true, backingTrack: false)
        #expect(event.name == "recording_started")
        #expect(event.parameters == [
            "input_type": .string("usb"), "channels": .int(2), "suppression": .string("high"), "auto_tune": .bool(true),
            "backing_track": .bool(false),
        ])
        let export = AnalyticsEvent.exportCompleted(output: .both, format: .flac, destination: .files, postAction: .keepProject)
        #expect(export.parameters == [
            "output": .string("both"), "format": .string("flac"), "destination": .string("files"), "post_action": .string("keepProject"),
        ])
        #expect(AnalyticsEvent.exportStarted(output: .video, format: nil).parameters == ["output": .string("video")])
    }

    @Test func failuresAndTargetsAreReducedToKinds() {
        #expect(ImportFailureReason(ImportError.noAudio) == .noAudio)
        #expect(ImportFailureReason(CancellationError()) == .other)
        #expect(LoudnessTargetKind(.custom(lufs: -23)) == .custom)
        #expect(LoudnessTargetKind(nil) == .off)
        #expect(InputType(.bluetooth) == .bluetooth)
    }
}

@MainActor
struct TelemetryConsentTests {
    @Test func nothingIsCollectedUntilAnsweredThenFollowsTheAnswerAndSettings() async {
        let consent = FakeConsentStore(), analytics = FakeAnalytics(), crashes = FakeCrashReporter()
        consent.sharesAnalytics = true
        let telemetry = TelemetryConsent(consent: consent, analytics: analytics, crashes: crashes)
        telemetry.start()
        #expect(!analytics.isEnabled, "not answered yet")
        #expect(!crashes.isEnabled)

        consent.recordAnswer(analytics: false, crashReports: true)
        await Task.yield()
        #expect(!analytics.isEnabled)
        #expect(crashes.isEnabled)

        consent.sharesAnalytics = true
        await Task.yield()
        #expect(analytics.isEnabled)
        consent.sharesCrashReports = false
        await Task.yield()
        #expect(!crashes.isEnabled)
    }
}
