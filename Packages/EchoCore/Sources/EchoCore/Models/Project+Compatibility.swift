extension Project {
    /// Values from a newer app version that this one can't write back unchanged. Such projects open read-only,
    /// like projects with a newer schema (SPEC § 5.3). Unknown AI operations don't count: they keep their raw
    /// kind, so the project stays editable.
    public var containsUnknownValues: Bool {
        mediaType == .unknown
            || origin == .unknown
            || outputLoudness?.isUnknown == true
            || clips.contains { clip in clip.manual.eq.contains { $0.kind == .unknown } }
            || recording.map { recording in
                recording.editingSource == .unknown || recording.markers.contains { $0.kind == .unknown }
                    || recording.parameterChanges.contains { $0.parameter == .unknown }
            } == true
    }
}
