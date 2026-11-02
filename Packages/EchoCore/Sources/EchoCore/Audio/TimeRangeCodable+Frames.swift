import AVFoundation

extension TimeRangeCodable {
    /// The range's frames in a file of `length` frames at `sampleRate`, clamped to the file. Auto Level analysis and
    /// the final render both read these, so the exported trim is exactly what was measured (SPEC § 6.7, § 11.2).
    func frames(sampleRate: Double, length: AVAudioFramePosition) -> Range<AVAudioFramePosition> {
        let first = min(max(AVAudioFramePosition((start * sampleRate).rounded()), 0), length)
        let last = min(max(AVAudioFramePosition((end * sampleRate).rounded()), first), length)
        return first..<last
    }
}
