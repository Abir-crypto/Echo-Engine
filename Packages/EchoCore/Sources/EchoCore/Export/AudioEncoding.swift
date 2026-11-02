import AVFoundation

/// Encodes the final render into the chosen export format (SPEC § 4.3 `ExportService`, § 11.2 step 3).
public protocol AudioEncoding: Sendable {
    /// Encodes `input` (the final render, float-readable audio) into `output`, whose extension must be
    /// `settings.format.fileExtension`. Reports progress 0…1 and stops when cancelled; a failed or cancelled encode
    /// leaves no file.
    func encode(_ input: URL, to output: URL, settings: AudioExportSettings, progress: @Sendable (Double) -> Void) async throws
}

/// Encodes one second at a time: AAC (constant bitrate), WAV (integer PCM), FLAC or ALAC. Resamples with the
/// mastering-quality converter when the rate differs, and adds TPDF dither before 16-bit output.
public struct AudioEncoder: AudioEncoding {
    static let chunkFrames: AVAudioFrameCount = 48_000

    public init() {}

    public func encode(_ input: URL, to output: URL, settings: AudioExportSettings, progress: @Sendable (Double) -> Void) async throws {
        guard settings.isSupported else { throw ExportError.unsupportedSettings }
        do {
            try run(input, to: output, settings: settings, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private func run(_ input: URL, to output: URL, settings: AudioExportSettings, progress: @Sendable (Double) -> Void) throws {
        let source: AVAudioFile
        do {
            source = try AVAudioFile(forReading: input)
        } catch {
            throw ExportError.unreadableAudio
        }
        let inputFormat = source.processingFormat
        let channelCount = inputFormat.channelCount
        try? FileManager.default.removeItem(at: output)
        let destination = try makeWriter(output, settings: settings, channelCount: channelCount)
        var dither = settings.format.isLossless && settings.bitDepth == 16 ? TPDFDither(bitDepth: 16) : nil
        let reader = try ChunkReader(source: source, outputFormat: destination.processingFormat)
        let total = Double(max(source.length, 1))
        progress(0)
        while let chunk = try reader.next() {
            try Task.checkCancellation()
            dither?.apply(to: chunk)
            try destination.write(chunk)
            progress(min(Double(source.framePosition) / total, 1))
        }
        try Task.checkCancellation()
        try destination.close()
        progress(1)
    }

    private func makeWriter(_ url: URL, settings: AudioExportSettings, channelCount: AVAudioChannelCount) throws -> any EncodedFileWriter {
        if settings.format == .flac {
            return try FLACFileWriter(url: url, sampleRate: settings.sampleRate, channelCount: channelCount, bitDepth: settings.bitDepth ?? 24)
        }
        do {
            return AVAudioFileWriter(file: try AVAudioFile(
                forWriting: url,
                settings: fileSettings(settings, channelCount: channelCount),
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            ))
        } catch {
            throw ExportError.cantWrite
        }
    }

    private func fileSettings(_ settings: AudioExportSettings, channelCount: AVAudioChannelCount) -> [String: Any] {
        var file: [String: Any] = [AVSampleRateKey: settings.sampleRate, AVNumberOfChannelsKey: channelCount]
        let bitDepth = settings.bitDepth ?? 24
        switch settings.format {
        case .aac:
            file[AVFormatIDKey] = kAudioFormatMPEG4AAC
            file[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_Constant
            file[AVEncoderBitRateKey] = Self.aacBitrate(settings.bitrate ?? 256_000, sampleRate: settings.sampleRate, channelCount: channelCount)
        case .wav:
            file[AVFormatIDKey] = kAudioFormatLinearPCM
            file[AVLinearPCMBitDepthKey] = bitDepth
            file[AVLinearPCMIsFloatKey] = false
            file[AVLinearPCMIsBigEndianKey] = false
            file[AVLinearPCMIsNonInterleaved] = false
        case .flac:
            // Written by `FLACFileWriter`; `AVAudioFile` would ignore the bit depth.
            file[AVFormatIDKey] = kAudioFormatFLAC
        case .alac:
            file[AVFormatIDKey] = kAudioFormatAppleLossless
            file[AVEncoderBitDepthHintKey] = bitDepth
        }
        return file
    }

    /// The requested bitrate, or the highest the AAC encoder takes below it (mono tops out lower than stereo).
    private static func aacBitrate(_ requested: Int, sampleRate: Double, channelCount: AVAudioChannelCount) -> Int {
        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount),
              let aac = AVAudioFormat(settings: [
                  AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channelCount,
              ]),
              let converter = AVAudioConverter(from: pcm, to: aac),
              let rates = converter.applicableEncodeBitRates?.map(\.intValue), let lowest = rates.min() else {
            return requested
        }
        return rates.filter { $0 <= requested }.max() ?? lowest
    }
}

/// An encoded file being written from float, non-interleaved buffers in `processingFormat`.
private protocol EncodedFileWriter: AnyObject {
    var processingFormat: AVAudioFormat { get }
    func write(_ buffer: AVAudioPCMBuffer) throws
    /// Finishes the file (flushes the encoder).
    func close() throws
}

private final class AVAudioFileWriter: EncodedFileWriter {
    private let file: AVAudioFile

    init(file: AVAudioFile) {
        self.file = file
    }

    var processingFormat: AVAudioFormat { file.processingFormat }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        do {
            try file.write(from: buffer)
        } catch {
            throw ExportError.cantWrite
        }
    }

    func close() throws {
        file.close()
    }
}

/// FLAC through `ExtAudioFile`: `AVAudioFile` writes every FLAC as 24-bit, whatever its settings ask.
private final class FLACFileWriter: EncodedFileWriter {
    let processingFormat: AVAudioFormat
    private var file: ExtAudioFileRef?

    init(url: URL, sampleRate: Double, channelCount: AVAudioChannelCount, bitDepth: Int) throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatFLAC,
            mFormatFlags: bitDepth == 16 ? kAppleLosslessFormatFlag_16BitSourceData : kAppleLosslessFormatFlag_24BitSourceData,
            mBytesPerPacket: 0,
            mFramesPerPacket: 4_096,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount),
              ExtAudioFileCreateWithURL(url as CFURL, kAudioFileFLACType, &description, nil, AudioFileFlags.eraseFile.rawValue, &file) == noErr,
              let file else {
            throw ExportError.cantWrite
        }
        processingFormat = format
        var client = format.streamDescription.pointee
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, size, &client) == noErr else {
            throw ExportError.cantWrite
        }
    }

    deinit {
        if let file { ExtAudioFileDispose(file) }
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let file, ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList) == noErr else {
            throw ExportError.cantWrite
        }
    }

    func close() throws {
        guard let file else { return }
        self.file = nil
        guard ExtAudioFileDispose(file) == noErr else { throw ExportError.cantWrite }
    }
}

/// Reads a file one second at a time in `outputFormat`'s sample rate (float, non-interleaved), resampling when needed.
private final class ChunkReader {
    private let source: AVAudioFile
    private let converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat
    private var finished = false

    init(source: AVAudioFile, outputFormat: AVAudioFormat) throws {
        self.source = source
        self.outputFormat = outputFormat
        let inputFormat = source.processingFormat
        guard inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved,
              inputFormat.channelCount == outputFormat.channelCount else {
            throw ExportError.unreadableAudio
        }
        if inputFormat.sampleRate == outputFormat.sampleRate {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { throw ExportError.unsupportedSettings }
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter.sampleRateConverterQuality = .max
            self.converter = converter
        }
    }

    /// The next chunk, or `nil` at the end.
    func next() throws -> AVAudioPCMBuffer? {
        guard !finished else { return nil }
        guard let converter else { return try read(AudioEncoder.chunkFrames) }
        let capacity = AVAudioFrameCount((Double(AudioEncoder.chunkFrames) * outputFormat.sampleRate / source.processingFormat.sampleRate).rounded(.up))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { throw ExportError.unsupportedSettings }
        var readError: (any Error)?
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
            do {
                guard let input = try self.read(min(requested, AudioEncoder.chunkFrames)) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            } catch {
                readError = error
                inputStatus.pointee = .endOfStream
                return nil
            }
        }
        if let readError { throw readError }
        switch status {
        case .haveData:
            return output
        case .endOfStream:
            finished = true
            return output.frameLength > 0 ? output : nil
        default:
            throw ExportError.cantWrite
        }
    }

    private func read(_ frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard source.framePosition < source.length else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: frames) else {
            throw ExportError.unreadableAudio
        }
        do {
            try source.read(into: buffer, frameCount: frames)
        } catch {
            throw ExportError.unreadableAudio
        }
        return buffer.frameLength > 0 ? buffer : nil
    }
}

/// Triangular (TPDF) dither of ±1 LSB at `bitDepth`, added before the encoder rounds to that depth, so quiet detail
/// becomes noise rather than distortion. Deterministic, so exports are reproducible.
struct TPDFDither {
    private let lsb: Float
    private var state: UInt32 = 0x9E37_79B9

    init(bitDepth: Int) {
        lsb = 1 / Float(1 << (bitDepth - 1))
    }

    mutating func apply(to buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            for frame in 0..<Int(buffer.frameLength) {
                samples[frame] += (uniform() - uniform()) * lsb
            }
        }
    }

    /// 0..<1, xorshift32.
    private mutating func uniform() -> Float {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return Float(state >> 8) / Float(1 << 24)
    }
}
