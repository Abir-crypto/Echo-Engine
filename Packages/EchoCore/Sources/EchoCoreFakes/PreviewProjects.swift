import EchoCore
import Foundation

/// The sample projects of the Home mockup, for previews and debug seeding. Dates are relative to `now`.
public enum PreviewProjects {
    public static func all(now: Date = Date()) -> [Project] {
        [
            make(1, "Beach vlog", .video, .imported, duration: 198, daysAgo: 0, processed: true, now: now),
            make(2, "Episode 12 with Maya", .audio, .recorded, duration: 2_885, daysAgo: 1, processed: true, now: now),
            make(3, "Coffee shop interview", .video, .imported, duration: 760, daysAgo: 4, processed: false, now: now),
            make(4, "Acoustic cover, take 3", .audio, .recorded, duration: 242, daysAgo: 7, processed: true, now: now),
            make(5, "Lecture recording", .audio, .imported, duration: 4_350, daysAgo: 10, processed: false, now: now),
            make(6, "Product demo", .video, .imported, duration: 58, daysAgo: 16, processed: false, now: now),
        ]
    }

    /// Overview levels shaped like the mockup's bars, for every sample.
    public static func overviews(for projects: [Project]) -> [UUID: [Float]] {
        let heights: [Float] = [30, 55, 40, 75, 60, 90, 45, 70, 35, 80, 65, 50, 85, 40, 60, 95, 55, 70, 30, 65, 45, 75, 40, 55]
        let levels = heights.flatMap { [$0 / 100, $0 / 110] }
        return Dictionary(uniqueKeysWithValues: projects.map { ($0.id, levels) })
    }

    private static func make(
        _ number: Int,
        _ title: String,
        _ mediaType: MediaType,
        _ origin: ProjectOrigin,
        duration: Double,
        daysAgo: Int,
        processed: Bool,
        now: Date
    ) -> Project {
        let isVideo = mediaType == .video
        let sourceInfo = SourceInfo(
            duration: duration,
            container: isVideo ? "com.apple.quicktime-movie" : "com.apple.coreaudio-format",
            audioCodec: isVideo ? "aac " : "lpcm",
            videoCodec: isVideo ? "hvc1" : nil,
            byteSize: Int64(duration * (isVideo ? 4_000_000 : 192_000)),
            channelCount: isVideo ? 2 : 1,
            sampleRate: 48_000
        )
        let updated = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        var project = Project(
            id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!,
            title: title,
            mediaType: mediaType,
            origin: origin,
            sourceFileName: isVideo ? "source.mov" : "source.caf",
            sourceInfo: sourceInfo,
            recording: origin == .recorded ? RecordingMetadata(channelNames: ["Host"]) : nil,
            createdAt: updated.addingTimeInterval(-3_600)
        )
        project.updatedAt = updated
        if processed {
            project.clips[0].aiStack = [AIOperation(kind: .noiseSuppression, strength: 0.8)]
        }
        return project
    }
}
