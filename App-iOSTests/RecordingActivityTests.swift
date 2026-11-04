import Foundation
@testable import EchoEngine
import Testing

struct MeterScaleTests {
    @Test func peaksMapFromMinus60dBToFullScale() {
        #expect(MeterScale.fraction(forPeak: 1) == 1)
        #expect(MeterScale.fraction(forPeak: 0.001) < 1e-6, "−60 dBFS")
        #expect(abs(MeterScale.fraction(forPeak: 0.5) - (1 - 6.0206 / 60)) < 1e-4, "−6 dBFS")
        #expect(MeterScale.fraction(forPeak: 2) == 1, "clipping stays at the top")
        #expect(MeterScale.fraction(forPeak: 0) == 0)
        #expect(MeterScale.fraction(forPeak: .nan) == 0)
        #expect(MeterScale.fraction(forPeak: 0.0001) == 0, "below the floor")
    }

    @Test func thirtySegmentsWithTheLastFourForClipping() {
        #expect(MeterScale.litSegments(0) == 0)
        #expect(MeterScale.litSegments(0.5) == 15)
        #expect(MeterScale.litSegments(1) == 30)
        #expect(MeterScale.litSegments(1.5) == 30)
        #expect(MeterScale.litSegments(.nan) == 0)
        #expect((0..<30).filter(MeterScale.isClipSegment) == [26, 27, 28, 29])
    }
}

@MainActor
struct RecordingStopRelayTests {
    @Test func stopReachesTheRecordingWhileOneIsOpen() async {
        let relay = RecordingStopRelay()
        await relay.stop()   // nothing recording: nothing happens
        var stops = 0
        relay.handler = { stops += 1 }
        await relay.stop()
        #expect(stops == 1)
    }

    @Test func theLiveActivityCarriesNoUserContent() throws {
        func keys(_ value: some Encodable) throws -> Set<String> {
            Set(try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]).keys)
        }
        let state = RecordingActivityAttributes.ContentState(timerStart: .now, pausedAt: .now, level: 0.5)
        #expect(try keys(RecordingActivityAttributes(tint: "amber")) == ["tint"])
        #expect(try keys(state) == ["timerStart", "pausedAt", "level"], "times and the level only: no title")
    }
}
