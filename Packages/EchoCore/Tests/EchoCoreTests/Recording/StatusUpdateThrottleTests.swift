import EchoCore
import Testing

struct StatusUpdateThrottleTests {
    @Test func sendsAboutTwiceASecondButPausingAtOnce() {
        var throttle = StatusUpdateThrottle(interval: .milliseconds(500))
        let start = ContinuousClock.now
        let sent = [
            (0, false), (100, false), (499, false), (500, false), (510, true), (520, false),
        ].map { milliseconds, isPaused in
            throttle.shouldSend(at: start + .milliseconds(milliseconds), isPaused: isPaused)
        }
        #expect(sent == [true, false, false, true, true, true], "first, throttled twice, after 500 ms, pausing and resuming at once")
        throttle.reset()
        let afterReset = throttle.shouldSend(at: start + .milliseconds(530), isPaused: false)
        #expect(afterReset)
    }
}
