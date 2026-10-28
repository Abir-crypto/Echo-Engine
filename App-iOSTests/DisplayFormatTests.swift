import Foundation
@testable import EchoEngine
import Testing

struct DisplayFormatTests {
    private let english = Locale(identifier: "en_US")
    private let german = Locale(identifier: "de_DE")

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
