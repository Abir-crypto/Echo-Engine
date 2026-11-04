import Foundation

/// A 32-bit float linear PCM CAF file written as it grows (SPEC § 13.3). The data chunk's size stays "unknown" (−1,
/// which CAF allows for the last chunk: it runs to the end of the file) until `close()` writes the real size, so the
/// file is valid after every append: a crash or kill keeps everything already written.
final class CAFWriter {
    let url: URL
    let channelCount: Int
    private(set) var frameCount: Int64 = 0
    private let handle: FileHandle
    private var interleaved: [Float] = []
    private var isClosed = false

    /// Byte offset of the data chunk's size field: file header (8) + `desc` chunk header (12) and body (32) + `data`
    /// chunk type (4).
    private static let dataSizeOffset: UInt64 = 56

    /// Creates the file; never replaces an existing one.
    init(url: URL, sampleRate: Double, channelCount: Int) throws {
        self.url = url
        self.channelCount = channelCount
        try Self.header(sampleRate: sampleRate, channelCount: channelCount).write(to: url, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    deinit {
        try? handle.close()
    }

    /// Appends `frames` frames of `channels` (one pointer per channel, non-interleaved).
    func append(_ channels: [UnsafePointer<Float>], frames: Int) throws {
        guard frames > 0 else { return }
        precondition(channels.count == channelCount, "One pointer per channel")
        if channelCount == 1 {
            try handle.write(contentsOf: UnsafeRawBufferPointer(start: channels[0], count: frames * MemoryLayout<Float>.size))
        } else {
            let samples = frames * channelCount
            if interleaved.count < samples { interleaved = [Float](repeating: 0, count: samples) }
            for frame in 0..<frames {
                for channel in 0..<channelCount {
                    interleaved[frame * channelCount + channel] = channels[channel][frame]
                }
            }
            try interleaved.withUnsafeBytes { bytes in
                try handle.write(contentsOf: UnsafeRawBufferPointer(rebasing: bytes.prefix(samples * MemoryLayout<Float>.size)))
            }
        }
        frameCount += Int64(frames)
    }

    /// Makes everything appended durable on disk (`fsync`).
    func synchronize() throws {
        try handle.synchronize()
    }

    /// Writes the data chunk's real size and closes the file. Without it the file stays valid with the unknown size.
    func close() throws {
        guard !isClosed else { return }
        isClosed = true
        defer { try? handle.close() }
        let dataBytes = Int64(MemoryLayout<UInt32>.size) + frameCount * Int64(channelCount * MemoryLayout<Float>.size)
        try handle.seek(toOffset: Self.dataSizeOffset)
        try handle.write(contentsOf: Self.bigEndian(UInt64(bitPattern: dataBytes)))
        try handle.synchronize()
    }

    /// File header, `desc` chunk (little-endian float samples, interleaved) and the `data` chunk's header with an unknown
    /// size and its edit count. CAF fields are big-endian.
    private static func header(sampleRate: Double, channelCount: Int) -> Data {
        let bytesPerFrame = UInt32(channelCount * MemoryLayout<Float>.size)
        let isFloat: UInt32 = 1 << 0, isLittleEndian: UInt32 = 1 << 1
        var data = Data()
        data += fourCharacterCode("caff") + bigEndian(UInt16(1)) + bigEndian(UInt16(0))
        data += fourCharacterCode("desc") + bigEndian(UInt64(32))
        data += bigEndian(sampleRate.bitPattern) + fourCharacterCode("lpcm") + bigEndian(isFloat | isLittleEndian)
        data += bigEndian(bytesPerFrame) + bigEndian(UInt32(1)) + bigEndian(UInt32(channelCount)) + bigEndian(UInt32(32))
        data += fourCharacterCode("data") + bigEndian(UInt64.max) + bigEndian(UInt32(0))
        return data
    }

    private static func fourCharacterCode(_ code: String) -> Data {
        Data(code.utf8)
    }

    private static func bigEndian<Value: FixedWidthInteger>(_ value: Value) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
