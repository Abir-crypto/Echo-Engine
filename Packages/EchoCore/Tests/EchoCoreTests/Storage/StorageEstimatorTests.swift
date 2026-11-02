import EchoCore
import EchoCoreFakes
import Foundation
import Testing

struct StorageEstimatorTests {
    private let estimator = StorageEstimator(volume: FileManager.default.temporaryDirectory)

    /// A 10-minute, 1 GB video.
    private func video(trimmedTo trim: TimeRangeCodable? = nil) -> Project {
        var project = Project(
            title: "Interview", mediaType: .video, origin: .imported, sourceFileName: "source.mov",
            sourceInfo: SourceInfo(
                duration: 600, container: "com.apple.quicktime-movie", audioCodec: "aac ", videoCodec: "hvc1",
                byteSize: 1_000_000_000, channelCount: 2, sampleRate: 48_000
            ),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        if let trim { project.trimRange = trim }
        return project
    }

    @Test func importNeedsSourcePlusFloatWorkingAudioPlusMargin() {
        // 1 GB + 600 s × 384 KB/s (230.4 MB) + 200 MB
        #expect(estimator.bytesToImport(video().sourceInfo) == 1_430_400_000)
    }

    @Test func editNeedsTwoRendersPlusMargin() {
        // 600 s × 100 KB/s × 2 (120 MB) + 200 MB
        #expect(estimator.bytesToEdit(video()) == 320_000_000)
    }

    @Test func exportNeedsTrimmedVideoRenderEncodedAudioAndMargin() {
        // Half the video: 500 MB + 300 s × (100 + 32) KB/s (39.6 MB) + 100 MB
        let half = video(trimmedTo: TimeRangeCodable(start: 150, duration: 300))
        #expect(estimator.bytesToExport(half) == 639_600_000)
    }

    @Test func audioExportHasNoVideoPart() {
        var audio = video()
        audio.mediaType = .audio
        // 600 s × 132 KB/s (79.2 MB) + 100 MB
        #expect(estimator.bytesToExport(audio) == 179_200_000)
    }

    @Test func exportEstimatesFollowTheChosenOutput() {
        let half = video(trimmedTo: TimeRangeCodable(start: 150, duration: 300))
        // 500 MB video + 300 s × (100 KB/s render + 40 KB/s AAC 320) + 100 MB
        #expect(estimator.bytesToExport(half, output: .video(audioBitrate: 320_000)) == 642_000_000)
        // 300 s × (100 KB/s + 176.4 KB/s WAV 16-bit 44.1 kHz stereo) + 100 MB
        let wav = AudioExportSettings(format: .wav, sampleRate: 44_100, bitDepth: 16, bitrate: nil)
        #expect(estimator.bytesToExport(half, output: .audioOnly(wav)) == 182_920_000)
        // FLAC/ALAC at 24-bit 48 kHz ≈ the render rate: 500 MB + 300 s × (100 + 24 + 100) KB/s + 100 MB
        #expect(estimator.bytesToExport(half, output: .both(audioBitrate: 192_000, .lossless)) == 667_200_000)
        // ALAC 16-bit 44.1 kHz: 100 KB/s × 44.1/48 × 16/24 = 61.25 KB/s
        let alac = AudioExportSettings(format: .alac, sampleRate: 44_100, bitDepth: 16, bitrate: nil)
        #expect(estimator.bytesToExport(half, output: .audioOnly(alac)) == 148_375_000)
    }

    @Test func theDefaultExportEstimateIsAVideoWithAAC256() {
        let half = video(trimmedTo: TimeRangeCodable(start: 150, duration: 300))
        #expect(estimator.bytesToExport(half) == estimator.bytesToExport(half, output: .video(audioBitrate: 256_000)))
    }

    @Test func availableBytesReadsTheVolume() throws {
        #expect(try estimator.availableBytes() > 0)
    }

    @Test func readinessReportsTheEditShortfallFirst() {
        let estimates = FakeStorageEstimator(editBytes: 2_400_000_000, exportBytes: 3_000_000_000)
        #expect(estimates.readiness(of: video(), availableBytes: 1_100_000_000) == .needsSpaceToEdit(1_300_000_000))
    }

    @Test func readinessReportsTheExportShortfallOnceEditingFits() {
        let estimates = FakeStorageEstimator(editBytes: 300_000_000, exportBytes: 1_300_000_000)
        #expect(estimates.readiness(of: video(), availableBytes: 1_100_000_000) == .needsSpaceToExport(200_000_000))
    }

    @Test func readinessIsReadyWhenEverythingFits() {
        let estimates = FakeStorageEstimator(editBytes: 300_000_000, exportBytes: 1_100_000_000)
        #expect(estimates.readiness(of: video(), availableBytes: 1_100_000_000) == .ready)
    }
}
