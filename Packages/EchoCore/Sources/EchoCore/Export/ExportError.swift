/// Why an export step failed (SPEC § 4.7). The app maps each case to an actionable message.
public enum ExportError: Error, Equatable {
    /// The audio to export can't be opened or read.
    case unreadableAudio
    /// The source video can't be opened, or has no video track.
    case unreadableVideo
    /// The output can't be written (e.g. no space left).
    case cantWrite
    /// Settings outside what the export sheet offers (SPEC § 11.1).
    case unsupportedSettings
    /// The person hasn't allowed adding to their photo library.
    case photoLibraryDenied
    /// Photos didn't take the video.
    case photoLibraryFailed
    /// The file couldn't be saved or shared at the chosen place.
    case deliveryFailed
}
