import Foundation

/// Steadies a live histogram: new histograms arrive now and then as targets,
/// and every frame the shown one glides part of the way towards the latest —
/// smooth motion at the frame rate, without the jitter of following every
/// sample.  How far it glides depends on the time since the last step, so it
/// moves at the same pace whatever the frame rate.
public struct HistogramSmoother: Sendable {
    /// How far the shown histogram moves towards the target in one
    /// `referenceStep` of time (0…1).
    public let stepFraction: Double
    public static let referenceStep: Duration = .milliseconds(33)
    private var target: [[Double]] = []
    private var shown: [[Double]] = []

    public init(stepFraction: Double = 0.2) {
        self.stepFraction = min(max(stepFraction, 0), 1)
    }

    /// The histogram to glide towards; the first one is shown as it is.
    public mutating func setTarget(_ histogram: Histogram) {
        target = [histogram.red, histogram.green, histogram.blue].map { $0.map(Double.init) }
        if shown.count != target.count || zip(shown, target).contains(where: { $0.count != $1.count }) {
            shown = target
        }
    }

    /// A step towards the target for `elapsed` time since the last one;
    /// nil before the first target.
    public mutating func step(after elapsed: Duration = referenceStep) -> Histogram? {
        guard !target.isEmpty else { return nil }
        let steps = max(elapsed / Self.referenceStep, 0)
        let fraction = 1 - pow(1 - stepFraction, steps)
        shown = zip(shown, target).map { channel, goal in
            zip(channel, goal).map { value, aim in value + fraction * (aim - value) }
        }
        let rounded = shown.map { $0.map { Int($0.rounded()) } }
        return Histogram(red: rounded[0], green: rounded[1], blue: rounded[2])
    }

    public mutating func reset() {
        target = []
        shown = []
    }
}
