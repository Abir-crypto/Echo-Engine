@testable import EchoCore
import Foundation
import Synchronization
import Testing

struct WaveformPeaksTests {
    /// 1,024 deterministic peaks in 0...1.
    private let values: [Float] = (0..<1_024).map { Float(($0 * 7_919) % 1_000) / 1_000 }
    private var waveform: WaveformPeaks {
        WaveformPeaks(sampleRate: 48_000, sourceFrameCount: Int64(values.count * WaveformPeaks.framesPerBucket), peaks: values)
    }
    private var bucketSeconds: Double { Double(WaveformPeaks.framesPerBucket) / 48_000 }

    @Test func oneValuePerBucketReadsTheBaseLevelExactly() {
        #expect(waveform.levels(from: 0, to: waveform.duration, count: values.count) == values)
        let slice = waveform.levels(from: 100 * bucketSeconds, to: 164 * bucketSeconds, count: 64)
        #expect(slice == Array(values[100..<164]))
    }

    @Test func alignedCoarseQueriesAreExact() {
        let coarse = waveform.levels(from: 0, to: waveform.duration, count: 64)
        let expected = stride(from: 0, to: values.count, by: 16).map { values[$0..<$0 + 16].max()! }
        #expect(coarse == expected)
    }

    @Test(arguments: [(0.13, 3.7, 17), (1.0, 2.0, 50), (0.0, 5.5, 3), (2.31, 2.33, 9)])
    func coarseQueriesNeverMissAPeak(_ start: Double, _ end: Double, _ count: Int) {
        let result = waveform.levels(from: start, to: end, count: count)
        let perValue = (end - start) / bucketSeconds / Double(count)
        for (index, value) in result.enumerated() {
            let first = Int((start / bucketSeconds + Double(index) * perValue).rounded(.down))
            let last = max(first + 1, Int((start / bucketSeconds + Double(index + 1) * perValue).rounded(.up)))
            let exact = values[max(first, 0)..<min(last, values.count)].max() ?? 0
            #expect(value >= exact)
            #expect(value <= values.max()!)
        }
    }

    @Test func timeOutsideTheSourceReadsZero() {
        #expect(waveform.levels(from: waveform.duration + 1, to: waveform.duration + 2, count: 4) == [0, 0, 0, 0])
        #expect(waveform.levels(from: -2, to: -1, count: 2) == [0, 0])
    }

    @Test func degenerateQueries() {
        #expect(waveform.levels(from: 0, to: 1, count: 0).isEmpty)
        #expect(waveform.levels(from: 1, to: 1, count: 3) == [0, 0, 0])
        #expect(WaveformPeaks(sampleRate: 48_000, sourceFrameCount: 0, peaks: []).levels(from: 0, to: 1, count: 2) == [0, 0])
    }

    @Test func fileFormatRoundTrips() throws {
        let decoded = try #require(WaveformPeaksFile.decode(WaveformPeaksFile.encode(waveform)))
        #expect(decoded == waveform)
        #expect(WaveformPeaksFile.decode(Data("not peaks".utf8)) == nil)
        var otherVersion = WaveformPeaksFile.encode(waveform)
        otherVersion[4] = 9
        #expect(WaveformPeaksFile.decode(otherVersion) == nil)
    }
}

private final class ProgressCount: Sendable {
    let count = Mutex(0)
    func record(_: Double) { count.withLock { $0 += 1 } }
}

final class CachedWaveformProviderTests {
    private let directory: URL
    private let provider: CachedWaveformProvider
    private let projectID = UUID()

    init() throws {
        directory = try TestMedia.makeDirectory()
        provider = CachedWaveformProvider(root: directory.appending(path: "Waveforms"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func peaksAreTheLoudestSampleOfAnyChannelPerBucket() async throws {
        // 1 s stereo: silence then 0.8 on the left; the right channel peaks at 0.3 throughout.
        let left = (0..<48_000).map { $0 < 24_000 ? Float(0) : Float(0.8) }
        let right = (0..<48_000).map { $0 % 2 == 0 ? Float(0.3) : Float(-0.3) }
        let audio = directory.appending(path: "working.caf")
        try TestMedia.writeSamples([left, right], to: audio)

        let waveform = try await provider.peaks(of: audio, projectID: projectID, key: "working") { _ in }

        #expect(waveform.sampleRate == 48_000)
        #expect(waveform.duration == 1)
        #expect(waveform.peaks.count == 188)
        #expect(waveform.peaks[0..<93].allSatisfy { $0 == 0.3 })
        #expect(waveform.peaks[94...].allSatisfy { $0 == 0.8 })
    }

    @Test func secondRequestComesFromTheCache() async throws {
        let audio = directory.appending(path: "working.caf")
        try TestMedia.writeSamples([Array(repeating: 0.5, count: 9_600)], to: audio)
        let progress = ProgressCount()

        let first = try await provider.peaks(of: audio, projectID: projectID, key: "working", progress: progress.record)
        let generatedCalls = progress.count.withLock { $0 }
        let second = try await provider.peaks(of: audio, projectID: projectID, key: "working", progress: progress.record)

        #expect(generatedCalls > 0)
        #expect(progress.count.withLock { $0 } == generatedCalls, "a cache hit reports no progress")
        #expect(second == first)
        let cacheFile = directory.appending(path: "Waveforms/\(projectID.uuidString)/working.peaks")
        #expect(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    @Test func changedSourceIsRegenerated() async throws {
        let audio = directory.appending(path: "render.caf")
        try TestMedia.writeSamples([Array(repeating: 0.5, count: 9_600)], to: audio)
        _ = try await provider.peaks(of: audio, projectID: projectID, key: "render") { _ in }

        try TestMedia.writeSamples([Array(repeating: 0.2, count: 19_200)], to: audio)
        let regenerated = try await provider.peaks(of: audio, projectID: projectID, key: "render") { _ in }

        #expect(regenerated.sourceFrameCount == 19_200)
        #expect(regenerated.peaks.allSatisfy { $0 == 0.2 })
    }

    @Test func removingKeysDeletesOnlyThoseWaveforms() async throws {
        let audio = directory.appending(path: "working.caf")
        try TestMedia.writeSamples([Array(repeating: 0.5, count: 4_800)], to: audio)
        _ = try await provider.peaks(of: audio, projectID: projectID, key: "working") { _ in }
        _ = try await provider.peaks(of: audio, projectID: projectID, key: "render-abc") { _ in }

        try await provider.remove(keys: ["render-abc", "render-missing"], projectID: projectID)

        let folder = directory.appending(path: "Waveforms/\(projectID.uuidString)")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "render-abc.peaks").path))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "working.peaks").path))
    }

    @Test func removeAllDeletesTheProjectsWaveforms() async throws {
        let audio = directory.appending(path: "working.caf")
        try TestMedia.writeSamples([Array(repeating: 0.5, count: 4_800)], to: audio)
        _ = try await provider.peaks(of: audio, projectID: projectID, key: "working") { _ in }

        try await provider.removeAll(projectID: projectID)

        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "Waveforms/\(projectID.uuidString)").path))
        try await provider.removeAll(projectID: UUID())
    }
}
