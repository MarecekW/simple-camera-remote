import Testing

@testable import CaptureCore

struct HistogramSmootherTests {
    private func histogram(_ value: Int) -> Histogram {
        let bins = [Int](repeating: value, count: 256)
        return Histogram(red: bins, green: bins, blue: bins)
    }

    @Test func showsNothingBeforeTheFirstSample() {
        var smoother = HistogramSmoother()
        #expect(smoother.step() == nil)
    }

    @Test func startsFromTheFirstSample() {
        var smoother = HistogramSmoother()
        smoother.setTarget(histogram(100))
        #expect(smoother.step() == histogram(100))
    }

    @Test func glidesTowardsANewSampleFrameByFrame() {
        var smoother = HistogramSmoother(stepFraction: 0.25)
        smoother.setTarget(histogram(100))
        _ = smoother.step()
        smoother.setTarget(histogram(200))
        #expect(smoother.step()?.red[0] == 125)
        #expect(smoother.step()?.red[0] == 144)  // 125 + 0.25 × 75
    }

    @Test func settlesOnTheTarget() {
        var smoother = HistogramSmoother()
        smoother.setTarget(histogram(0))
        _ = smoother.step()
        smoother.setTarget(histogram(1000))
        var latest: Histogram?
        for _ in 0..<60 { latest = smoother.step() }
        #expect(latest?.red[0] == 1000)
    }

    @Test func movesAtTheSamePaceWhateverTheFrameRate() {
        var fast = HistogramSmoother(stepFraction: 0.2)
        var slow = HistogramSmoother(stepFraction: 0.2)
        fast.setTarget(histogram(0))
        slow.setTarget(histogram(0))
        _ = fast.step()
        _ = slow.step()
        fast.setTarget(histogram(1000))
        slow.setTarget(histogram(1000))
        var fastResult: Histogram?
        for _ in 0..<3 { fastResult = fast.step(after: HistogramSmoother.referenceStep) }
        let slowResult = slow.step(after: HistogramSmoother.referenceStep * 3)
        #expect(fastResult == slowResult)
    }
}
