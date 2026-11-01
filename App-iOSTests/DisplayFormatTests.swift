import Foundation
@testable import EchoEngine
import Testing

struct DisplayFormatTests {
    private let english = Locale(identifier: "en_US")
    private let german = Locale(identifier: "de_DE")

    @Test func adjustValuesUseUnitsAndLocaleNumbers() {
        #expect(DisplayFormat.decibels(2.5, locale: english) == "+2.5 dB")
        #expect(DisplayFormat.decibels(-6, locale: english) == "-6.0 dB")
        #expect(DisplayFormat.decibels(0, locale: english) == "0.0 dB")
        #expect(DisplayFormat.decibels(2.5, locale: german) == "+2,5 dB")
        #expect(DisplayFormat.lufs(-14, locale: english) == "-14 LUFS")
        #expect(DisplayFormat.lufs(-23.5, locale: english) == "-23.5 LUFS")
        #expect(DisplayFormat.lufs(-23.5, locale: german) == "-23,5 LUFS")
        #expect(DisplayFormat.frequency(80, locale: english) == "80 Hz")
        #expect(DisplayFormat.frequency(1_234, locale: english) == "1.2 kHz")
        #expect(DisplayFormat.frequency(12_000, locale: english) == "12 kHz")
        #expect(DisplayFormat.compactFrequency(250, locale: english) == "250")
        #expect(DisplayFormat.compactFrequency(1_000, locale: english) == "1K")
        #expect(DisplayFormat.compactFrequency(12_000, locale: english) == "12K")
        #expect(DisplayFormat.milliseconds(0.54, locale: english) == "0.5 ms")
        #expect(DisplayFormat.milliseconds(150.4, locale: english) == "150 ms")
        #expect(DisplayFormat.ratio(3, locale: english) == "3:1")
        #expect(DisplayFormat.ratio(2.5, locale: english) == "2.5:1")
        #expect(DisplayFormat.percent(0.5, locale: english) == "50%")
        #expect(DisplayFormat.quality(0.71, locale: english) == "0.71")
        #expect(DisplayFormat.semitones(2, locale: english) == "+2")
        #expect(DisplayFormat.semitones(-3, locale: english) == "-3")
        #expect(DisplayFormat.semitones(0, locale: english) == "0")
    }

    @Test func fileSizeUsesDecimalUnitsAndLocaleSeparators() {
        #expect(DisplayFormat.fileSize(2_400_000_000, locale: english) == "2.4 GB")
        #expect(DisplayFormat.fileSize(2_400_000_000, locale: german) == "2,4\u{00A0}GB")
    }

    @Test(arguments: [
        (245.9, "4:05"),
        (3599, "59:59"),
        (3600, "1:00:00"),
        (3723, "1:02:03"),
    ])
    func durationSwitchesToHoursFromOneHour(_ seconds: TimeInterval, _ expected: String) {
        #expect(DisplayFormat.duration(seconds, locale: english) == expected)
    }

    @Test func projectDateIsRelativeForTodayAndYesterdayThenShort() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let british = Locale(identifier: "en_GB")
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 15)))
        func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
        }
        func format(_ date: Date) -> String {
            DisplayFormat.projectDate(date, now: now, calendar: calendar, locale: british)
        }

        #expect(try format(date(2026, 10, 28, hour: 0)) == "Edited today")
        #expect(try format(date(2026, 10, 27, hour: 23)) == "Yesterday")
        #expect(try format(date(2026, 10, 21)) == "21 Oct")
        #expect(try format(date(2025, 12, 31)) == "31 Dec 2025")
    }
}
