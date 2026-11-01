@testable import EchoCore
import Testing

struct EQResponseTests {
    @Test func defaultBandsAreFlat() {
        let response = EQResponse.magnitudeDB(of: EQBand.defaultBands, at: EQResponse.logFrequencies(count: 32))
        #expect(response.allSatisfy { $0 == 0 })
        #expect(EQResponse.isFlat(EQBand.defaultBands))
    }

    @Test func aBoostShowsAtItsFrequency() {
        var bands = EQBand.defaultBands
        bands[2].gainDB = 6
        let response = EQResponse.magnitudeDB(of: bands, at: [1_000, 100, 10_000])
        #expect(abs(response[0] - 6) < 0.01)
        #expect(abs(response[1]) < 0.5)
        #expect(abs(response[2]) < 0.5)
        #expect(!EQResponse.isFlat(bands))
    }

    @Test func frequenciesSpanTheAudibleRangeOnALogScale() {
        let frequencies = EQResponse.logFrequencies(count: 4)
        #expect(abs(frequencies[0] - 20) < 1e-9)
        #expect(abs(frequencies[1] - 200) < 1e-6)
        #expect(abs(frequencies[3] - 20_000) < 1e-6)
    }
}
