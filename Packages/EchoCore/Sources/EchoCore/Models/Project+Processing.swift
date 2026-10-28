extension Project {
    /// Whether any processing is set: an AI step, a manual change or an Auto Level target. Home shows processed
    /// projects with tinted waveforms and unprocessed ones in grey (SPEC § 14.1).
    public var isProcessed: Bool {
        outputLoudness != nil || clips.contains { !$0.aiStack.isEmpty || $0.manual != ManualSettings() }
    }
}
