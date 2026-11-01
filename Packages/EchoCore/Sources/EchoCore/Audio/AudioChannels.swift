import AVFoundation

/// Moves audio between `AVAudioPCMBuffer` and per-channel float arrays, converting with `AVAudioConverter`.
enum AudioChannels {
    /// The channels of `buffer` as 48 kHz floats (SPEC § 6.2); converted when the buffer is in another format.
    static func float48k(_ buffer: AVAudioPCMBuffer) throws -> [[Float]] {
        guard let target = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: buffer.format.channelCount) else {
            throw AudioChannelsError.unsupportedFormat
        }
        let source = buffer.format == target ? buffer : try convert(buffer, to: target)
        guard let data = source.floatChannelData else { throw AudioChannelsError.unsupportedFormat }
        return (0..<Int(target.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: data[channel], count: Int(source.frameLength)))
        }
    }

    /// A deinterleaved float buffer holding `channels` (all the same length).
    static func buffer(_ channels: [[Float]], sampleRate: Double) throws -> AVAudioPCMBuffer {
        let frames = channels.first?.count ?? 0
        guard !channels.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels.count)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1))),
              let data = buffer.floatChannelData else {
            throw AudioChannelsError.unsupportedFormat
        }
        for (index, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { data[index].update(from: $0.baseAddress!, count: min(samples.count, frames)) }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw AudioChannelsError.unsupportedFormat
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1_024
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AudioChannelsError.unsupportedFormat
        }
        var isSupplied = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            if isSupplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            isSupplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { throw conversionError ?? AudioChannelsError.conversionFailed }
        return converted
    }
}

enum AudioChannelsError: Error, Equatable {
    case unsupportedFormat
    case conversionFailed
}
