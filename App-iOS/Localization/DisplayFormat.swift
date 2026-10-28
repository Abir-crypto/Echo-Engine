import Foundation

/// Locale-aware formatting for user-facing values (SPEC § 17).
///
/// Localization conventions for the app:
/// - UI text is a SwiftUI string literal (`Text("Export")`) or `String(localized:)`; keys live in
///   `Localizable.xcstrings` with English as the source language.
/// - Never concatenate localized fragments. Use one key with interpolated values; plurals are catalog variations.
/// - EchoCore produces no user-facing text: the app maps domain values and errors to localized strings.
/// - Numbers, sizes, durations and dates always go through formatters (this type), never string building.
/// - Time-based views (waveforms, trim strip, meters, EQ graph, transport icons) force left-to-right.
enum DisplayFormat {
    /// File size, e.g. "2.4 GB" (decimal units, as shown by Files and Settings).
    static func fileSize(_ bytes: Int64, locale: Locale = .autoupdatingCurrent) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }

    /// Media duration: "4:05" below one hour, "1:02:03" from one hour.
    static func duration(_ seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(seconds.rounded(.down)).formatted(.time(pattern: pattern).locale(locale))
    }
}
