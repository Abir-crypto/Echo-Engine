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
}
