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
        // A number even for nothing ("0 bytes", not "Zero kB").
        bytes.formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
    }

    /// Media duration: "4:05" below one hour, "1:02:03" from one hour.
    static func duration(_ seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(seconds.rounded(.down)).formatted(.time(pattern: pattern).locale(locale))
    }

    /// A level in decibels with one decimal and a sign: "+2.5 dB", "-6.0 dB", "0.0 dB".
    static func decibels(_ value: Float, locale: Locale = .autoupdatingCurrent) -> String {
        let number = Double(value).formatted(
            .number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)).locale(locale)
        )
        return String(localized: "\(number) dB", locale: locale, comment: "A level in decibels, e.g. +2.5 dB.")
    }

    /// A loudness target: "-14 LUFS", "-23.5 LUFS".
    static func lufs(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
        return String(localized: "\(number) LUFS", locale: locale, comment: "A loudness target, e.g. -14 LUFS.")
    }

    /// "80 Hz", "250 Hz", "1.2 kHz", "12 kHz".
    static func frequency(_ hertz: Float, locale: Locale = .autoupdatingCurrent) -> String {
        let measurement = hertz >= 1_000
            ? Measurement(value: (Double(hertz) / 100).rounded() / 10, unit: UnitFrequency.kilohertz)
            : Measurement(value: Double(hertz).rounded(), unit: UnitFrequency.hertz)
        return measurement.formatted(
            .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1)))
                .locale(locale)
        )
    }

    /// A short frequency for tight spaces such as EQ band chips: "250", "1K", "12K" (in the locale's compact form).
    static func compactFrequency(_ hertz: Float, locale: Locale = .autoupdatingCurrent) -> String {
        Double(hertz).formatted(.number.notation(.compactName).precision(.significantDigits(1...2)).locale(locale))
    }

    /// "0.5 ms", "150 ms".
    static func milliseconds(_ value: Float, locale: Locale = .autoupdatingCurrent) -> String {
        let rounded = value < 10 ? (Double(value) * 10).rounded() / 10 : Double(value).rounded()
        return Measurement(value: rounded, unit: UnitDuration.milliseconds).formatted(
            .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1)))
                .locale(locale)
        )
    }

    /// A compression ratio: "3:1", "2.5:1".
    static func ratio(_ value: Float, locale: Locale = .autoupdatingCurrent) -> String {
        let number = Double(value).formatted(.number.precision(.fractionLength(0...1)).locale(locale))
        return String(localized: "\(number):1", locale: locale, comment: "A compression ratio, e.g. 3:1.")
    }

    /// A 0…1 amount as a percentage: "50%".
    static func percent(_ value: Float, locale: Locale = .autoupdatingCurrent) -> String {
        Double(value).formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// An EQ band's Q: "0.71", "1.0".
    static func quality(_ value: Float, locale: Locale = .autoupdatingCurrent) -> String {
        Double(value).formatted(.number.precision(.fractionLength(1...2)).locale(locale))
    }

    /// Pitch shift in whole semitones, signed: "+2", "-3", "0".
    static func semitones(_ value: Float, locale: Locale = .autoupdatingCurrent) -> String {
        Int(value.rounded()).formatted(.number.sign(strategy: .always(includingZero: false)).locale(locale))
    }

    /// The pitch shift spoken by VoiceOver: "2 semitones higher", "Original pitch".
    static func semitonesDescription(_ value: Float) -> String {
        let steps = Int(value.rounded())
        if steps > 0 { return String(localized: "\(steps) semitones higher", comment: "VoiceOver value of the pitch slider.") }
        if steps < 0 { return String(localized: "\(-steps) semitones lower", comment: "VoiceOver value of the pitch slider.") }
        return String(localized: "Original pitch", comment: "VoiceOver value of the pitch slider at 0.")
    }

    /// When a project was last changed, for Home cards: "Edited today", "Yesterday", "21 Oct"; earlier years
    /// add the year.
    /// A meter position (0…1 on `MeterScale`) as whole decibels: "-12 dB", "0 dB"; silence shows the meter's floor.
    static func meterLevel(_ fraction: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let db = Int((MeterScale.floorDB * (1 - min(1, max(0, fraction.isFinite ? fraction : 0)))).rounded())
        let number = db.formatted(.number.locale(locale))
        return String(localized: "\(number) dB", locale: locale, comment: "A level in decibels, e.g. +2.5 dB.")
    }

    /// Default title of a recorded project (SPEC § 5.4), e.g. "Recording, 28 Oct 2026, 15:42".
    static func recordingTitle(
        _ date: Date, timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent
    ) -> String {
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone)
        let day = date.formatted(style.day().month(.abbreviated).year())
        let time = date.formatted(style.hour().minute())
        return String(
            localized: "Recording, \(day), \(time)", locale: locale,
            comment: "Default title of a recorded project: the date and time it was recorded, e.g. Recording, 28 Oct 2026, 15:42."
        )
    }

    static func projectDate(
        _ date: Date,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return String(localized: "Edited today")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .day().month(.abbreviated)
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) {
            style = style.year()
        }
        return date.formatted(style)
    }
}
