import Foundation

/// Waveform peaks for the editor, generated once per audio file and cached (SPEC § 9).
public protocol WaveformProviding: Sendable {
    /// Peaks of `audio`, cached under `key` for `projectID` (e.g. `working`, or a render's chain hash).
    /// `progress` (0...1) is only called while generating.
    func peaks(
        of audio: URL,
        projectID: UUID,
        key: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> WaveformPeaks
    /// Deletes the cached waveforms stored under `keys` (e.g. of renders the janitor removed).
    func remove(keys: Set<String>, projectID: UUID) async throws
    /// Deletes every cached waveform of the project.
    func removeAll(projectID: UUID) async throws
}

public enum WaveformError: Error, Equatable {
    case unreadable
}

extension URL {
    /// `Library/Caches/Waveforms`: regenerable peaks, never backed up.
    public static var waveformCacheDirectory: URL {
        .cachesDirectory.appending(path: "Waveforms", directoryHint: .isDirectory)
    }
}
