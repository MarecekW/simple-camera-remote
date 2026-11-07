/// A steady frames-per-second reading for a stream: averaged over a few
/// seconds and changed at most once a second, so it doesn't flicker between
/// neighbouring values.  Time is passed in, so it can be tested.
public struct FrameRateMeter: Sendable {
    public typealias Instant = ContinuousClock.Instant

    /// The reading, in whole frames per second.
    public private(set) var framesPerSecond = 0

    private let window: Duration
    private let updateInterval: Duration
    private var frameTimes: [Instant] = []
    private var lastUpdate: Instant?

    public init(window: Duration = .seconds(3), updateInterval: Duration = .seconds(1)) {
        self.window = window
        self.updateInterval = updateInterval
    }

    /// Counts a frame shown at `time`.
    public mutating func frame(at time: Instant) {
        frameTimes.append(time)
        update(at: time)
    }

    /// Updates the reading at `time` without a frame — while frames don't
    /// come, it falls as old ones leave the window.
    public mutating func update(at time: Instant) {
        let window = window
        frameTimes.removeAll { time - $0 > window }
        if let lastUpdate, time - lastUpdate < updateInterval { return }
        lastUpdate = time
        // Over the time covered so far, so the first seconds aren't too low.
        let seconds = min(time - (frameTimes.first ?? time), window) / .seconds(1)
        framesPerSecond =
            seconds > 0.5 ? Int((Double(frameTimes.count - 1) / seconds).rounded()) : frameTimes.count
    }

    public mutating func reset() {
        self = FrameRateMeter(window: window, updateInterval: updateInterval)
    }
}
