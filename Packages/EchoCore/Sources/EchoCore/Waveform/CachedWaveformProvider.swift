import AVFoundation

/// Caches peaks as `<root>/<projectID>/<key>.peaks`. A cached file is reused only while its recorded frame count
/// matches the audio file.
public actor CachedWaveformProvider: WaveformProviding {
    private let root: URL
    private let fileManager = FileManager()

    public init(root: URL) {
        self.root = root
    }

    public func peaks(
        of audio: URL,
        projectID: UUID,
        key: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> WaveformPeaks {
        let cacheFile = root.appending(path: projectID.uuidString).appending(path: "\(key).peaks")
        if let data = try? Data(contentsOf: cacheFile),
           let cached = WaveformPeaksFile.decode(data),
           let frameCount = try? AVAudioFile(forReading: audio).length,
           cached.sourceFrameCount == frameCount {
            return cached
        }
        let generated = try await WaveformPeaksGenerator.generate(from: audio, progress: progress)
        try fileManager.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WaveformPeaksFile.encode(generated).write(to: cacheFile, options: .atomic)
        return generated
    }

    public func remove(keys: Set<String>, projectID: UUID) throws {
        let folder = root.appending(path: projectID.uuidString)
        for key in keys {
            let file = folder.appending(path: "\(key).peaks")
            if fileManager.fileExists(atPath: file.path) {
                try fileManager.removeItem(at: file)
            }
        }
    }

    public func removeAll(projectID: UUID) throws {
        let folder = root.appending(path: projectID.uuidString)
        if fileManager.fileExists(atPath: folder.path) {
            try fileManager.removeItem(at: folder)
        }
    }
}

/// Binary layout, little-endian: "EEWP", version, sample rate, frames per bucket, source frames, count, peaks.
enum WaveformPeaksFile {
    static let magic = Array("EEWP".utf8)
    static let version: UInt32 = 1
    static let headerSize = 32

    static func encode(_ waveform: WaveformPeaks) -> Data {
        var data = Data(capacity: headerSize + waveform.peaks.count * 4)
        data.append(contentsOf: magic)
        append(version, to: &data)
        append(waveform.sampleRate.bitPattern, to: &data)
        append(UInt32(WaveformPeaks.framesPerBucket), to: &data)
        append(UInt64(bitPattern: waveform.sourceFrameCount), to: &data)
        append(UInt32(waveform.peaks.count), to: &data)
        for peak in waveform.peaks {
            append(peak.bitPattern, to: &data)
        }
        return data
    }

    /// `nil` for anything this version didn't write.
    static func decode(_ data: Data) -> WaveformPeaks? {
        guard data.count >= headerSize, Array(data.prefix(4)) == magic else { return nil }
        return data.withUnsafeBytes { bytes -> WaveformPeaks? in
            func read<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
                T(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: T.self))
            }
            guard read(UInt32.self, at: 4) == version,
                  read(UInt32.self, at: 16) == UInt32(WaveformPeaks.framesPerBucket)
            else { return nil }
            let sampleRate = Double(bitPattern: read(UInt64.self, at: 8))
            let sourceFrameCount = Int64(bitPattern: read(UInt64.self, at: 20))
            let count = Int(read(UInt32.self, at: 28))
            guard data.count == headerSize + count * 4 else { return nil }
            let peaks = (0..<count).map { Float(bitPattern: read(UInt32.self, at: headerSize + $0 * 4)) }
            return WaveformPeaks(sampleRate: sampleRate, sourceFrameCount: sourceFrameCount, peaks: peaks)
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
