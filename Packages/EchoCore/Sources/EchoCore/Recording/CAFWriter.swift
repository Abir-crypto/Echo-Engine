import Foundation

/// A 32-bit float linear PCM CAF file written as it grows (SPEC § 13.3). The data chunk's size stays "unknown" (−1,
/// which CAF allows for the last chunk: it runs to the end of the file) until `close()` writes the real size, so the
/// file is valid after every append: a crash or kill keeps everything already written.
public final class CAFWriter {
    public let url: URL
    public let channelCount: Int
    public private(set) var frameCount: Int64 = 0
    private let handle: FileHandle
    private var interleaved: [Float] = []
    private var isClosed = false

    /// Byte offset of the data chunk's size field: file header (8) + `desc` chunk header (12) and body (32) + `data`
    /// chunk type (4).
    private static let dataSizeOffset: UInt64 = 56

    /// Creates the file; never replaces an existing one.
    public init(url: URL, sampleRate: Double, channelCount: Int) throws {
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
    public func append(_ channels: [UnsafePointer<Float>], frames: Int) throws {
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
    public func synchronize() throws {
        try handle.synchronize()
    }

    /// Writes the data chunk's real size and closes the file. Without it the file stays valid with the unknown size.
    public func close() throws {
        guard !isClosed else { return }
        isClosed = true
        defer { try? handle.close() }
        let dataBytes = Int64(MemoryLayout<UInt32>.size) + frameCount * Int64(channelCount * MemoryLayout<Float>.size)
        try handle.seek(toOffset: Self.dataSizeOffset)
        try handle.write(contentsOf: Self.bigEndian(UInt64(bitPattern: dataBytes)))
        try handle.synchronize()
    }

    /// Audio frames in a file this type wrote, also while its data size is still unknown (the app was killed while
    /// writing it).
    static func frameCount(at url: URL) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try layout(of: handle).frames
    }

    /// Writes the data size of a file the app was killed while writing, dropping a partly written last frame. Leaves
    /// a finished file alone. Returns its frames.
    @discardableResult
    static func finish(at url: URL) throws -> Int64 {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let layout = try layout(of: handle)
        guard layout.isUnfinished else { return layout.frames }
        let dataBytes = layout.frames * layout.bytesPerFrame
        try handle.truncate(atOffset: UInt64(headerSize + dataBytes))
        try handle.seek(toOffset: dataSizeOffset)
        try handle.write(contentsOf: bigEndian(UInt64(bitPattern: Int64(MemoryLayout<UInt32>.size) + dataBytes)))
        try handle.synchronize()
        return layout.frames
    }

    /// Bytes before the samples: file header, `desc` chunk, `data` chunk header and edit count.
    private static let headerSize: Int64 = 68

    private struct Layout {
        let bytesPerFrame: Int64
        let frames: Int64
        let isUnfinished: Bool
    }

    /// Reads the header this type writes; anything else is refused.
    private static func layout(of handle: FileHandle) throws -> Layout {
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: Int(headerSize)), header.count == headerSize,
              header[0..<4] == fourCharacterCode("caff"), header[8..<12] == fourCharacterCode("desc"),
              header[52..<56] == fourCharacterCode("data") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        func integer<Value: FixedWidthInteger>(_ offset: Int, as _: Value.Type) -> Value {
            header[offset..<offset + MemoryLayout<Value>.size].reduce(0) { $0 << 8 | Value($1) }
        }
        let bytesPerFrame = Int64(integer(36, as: UInt32.self))
        guard bytesPerFrame > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let dataSize = integer(Int(dataSizeOffset), as: UInt64.self)
        if dataSize == .max {
            let fileSize = Int64(try handle.seekToEnd())
            return Layout(bytesPerFrame: bytesPerFrame, frames: max(0, fileSize - headerSize) / bytesPerFrame, isUnfinished: true)
        }
        return Layout(bytesPerFrame: bytesPerFrame, frames: (Int64(dataSize) - 4) / bytesPerFrame, isUnfinished: false)
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
