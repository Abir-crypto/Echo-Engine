import AVFoundation

/// One take file at 48 kHz (SPEC § 13.2, § 13.3): input at another rate (Bluetooth headsets run at 16 or 24 kHz) is
/// converted while writing.
final class TakeStream {
    private let writer: CAFWriter
    private let converter: Converter?

    /// Frames written to the file, at 48 kHz.
    var frameCount: Int64 { writer.frameCount }

    /// `maximumFrames` is the most input frames one `append` passes. The file exists only when this succeeds.
    init(url: URL, channelCount: Int, inputSampleRate: Double, maximumFrames: Int) throws {
        converter = inputSampleRate == RecordingConfiguration.sampleRate
            ? nil
            : try Converter(channelCount: channelCount, inputSampleRate: inputSampleRate, maximumFrames: maximumFrames)
        writer = try CAFWriter(url: url, sampleRate: RecordingConfiguration.sampleRate, channelCount: channelCount)
    }

    /// Appends `frames` input frames (one pointer per channel).
    func append(_ channels: [UnsafePointer<Float>], frames: Int) throws {
        guard let converter else { return try writer.append(channels, frames: frames) }
        try converter.convert(channels, frames: frames) { try writer.append($0, frames: $1) }
    }

    func synchronize() throws {
        try writer.synchronize()
    }

    /// Writes the converter's last frames and closes the file. Best effort: whatever was written stays readable.
    func finish() {
        try? converter?.flush { try writer.append($0, frames: $1) }
        try? writer.close()
    }

    private struct ConversionFailed: Error {}

    /// Streams input at one rate into 48 kHz.
    private final class Converter {
        private let converter: AVAudioConverter
        private let input: AVAudioPCMBuffer
        private let output: AVAudioPCMBuffer

        init(channelCount: Int, inputSampleRate: Double, maximumFrames: Int) throws {
            guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: inputSampleRate, channels: AVAudioChannelCount(channelCount)),
                  let outputFormat = AVAudioFormat(
                      standardFormatWithSampleRate: RecordingConfiguration.sampleRate, channels: AVAudioChannelCount(channelCount)
                  ),
                  let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
                  let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(maximumFrames)),
                  let output = AVAudioPCMBuffer(
                      pcmFormat: outputFormat,
                      frameCapacity: AVAudioFrameCount((Double(maximumFrames) * RecordingConfiguration.sampleRate / inputSampleRate).rounded(.up)) + 1_024
                  ) else {
                throw RecordingError.cantCreateFiles
            }
            converter.sampleRateConverterQuality = .max
            self.converter = converter
            self.input = input
            self.output = output
        }

        func convert(_ channels: [UnsafePointer<Float>], frames: Int, write: ([UnsafePointer<Float>], Int) throws -> Void) throws {
            for (index, samples) in channels.enumerated() {
                input.floatChannelData![index].update(from: samples, count: frames)
            }
            input.frameLength = AVAudioFrameCount(frames)
            try run(endOfStream: false, write: write)
        }

        func flush(write: ([UnsafePointer<Float>], Int) throws -> Void) throws {
            try run(endOfStream: true, write: write)
        }

        /// Converts the pending input (none when flushing), writing the output as it fills.
        private func run(endOfStream: Bool, write: ([UnsafePointer<Float>], Int) throws -> Void) throws {
            var isSupplied = endOfStream
            while true {
                output.frameLength = 0
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, inputStatus in
                    if isSupplied {
                        inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                        return nil
                    }
                    isSupplied = true
                    inputStatus.pointee = .haveData
                    return self.input
                }
                guard status != .error else { throw ConversionFailed() }
                let channels = (0..<Int(output.format.channelCount)).map { UnsafePointer(output.floatChannelData![$0]) }
                try write(channels, Int(output.frameLength))
                // `.haveData`: the output filled up and more is pending.
                guard status == .haveData else { return }
            }
        }
    }
}
