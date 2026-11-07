import CaptureCore
import Testing

struct FrameRateMeterTests {
    private let start = ContinuousClock.now

    @Test func holdsSteadyAtAnUnevenRate() {
        var meter = FrameRateMeter()
        var readings: Set<Int> = []
        // 30.4 fps with jitter: a one-second count would flip between 30 and 31.
        for index in 0..<200 {
            let jitter = index.isMultiple(of: 3) ? 4 : 0
            meter.frame(at: start + .milliseconds(index * 1000 / 30 - index / 12 + jitter))
            if index > 100 { readings.insert(meter.framesPerSecond) }
        }
        #expect(readings == [30])
    }

    @Test func changesAtMostOnceASecond() {
        var meter = FrameRateMeter()
        meter.frame(at: start)
        meter.frame(at: start + .milliseconds(600))
        let first = meter.framesPerSecond
        meter.frame(at: start + .milliseconds(700))
        #expect(meter.framesPerSecond == first)
    }

    @Test func fallsWhenFramesStop() {
        var meter = FrameRateMeter()
        for index in 0..<90 { meter.frame(at: start + .milliseconds(index * 33)) }
        #expect(meter.framesPerSecond == 30)
        meter.update(at: start + .seconds(7))
        #expect(meter.framesPerSecond == 0)
    }
}
