import Foundation

/// Pixels per millimetre measured on a capture: a known length (e.g. on a
/// ruler) marked by its two ends on the full-resolution image.  Unlike
/// `ResolutionEstimate`, a measurement — but only for the setup it was
/// measured in: the capture it came from is kept, so its sidecar tells the
/// distance, and the focal length is kept to tell when the zoom has moved.
public struct MeasuredScale: Codable, Equatable, Sendable {
    /// Image pixels per millimetre of subject.
    public var pixelsPerMillimetre: Double
    /// The measured span in image pixels, and its known length.
    public var pixels: Double
    public var millimetres: Double
    /// The capture it was measured on (its name without extension).
    public var capture: String
    /// That capture's focal length in thousandths of a millimetre, as the
    /// camera reported it; nil when unknown (and in sessions from before it
    /// was kept).
    public var focalLength: UInt32?

    /// Nil unless both lengths are positive and finite.
    public init?(pixels: Double, millimetres: Double, capture: String, focalLength: UInt32? = nil) {
        guard pixels > 0, pixels.isFinite, millimetres > 0, millimetres.isFinite else { return nil }
        self.pixels = pixels
        self.millimetres = millimetres
        self.capture = capture
        self.focalLength = focalLength
        pixelsPerMillimetre = pixels / millimetres
    }

    /// Whether the lens has zoomed away from where this was measured, so it
    /// no longer holds.  A scale without a known focal length can't tell,
    /// and is taken as it is.
    public func isStale(atFocalLength current: UInt32?) -> Bool {
        guard let focalLength else { return false }
        return current != focalLength
    }

    /// The pixels between two points on the image.
    public static func pixels(from start: CGPoint, to end: CGPoint) -> Double {
        hypot(end.x - start.x, end.y - start.y)
    }
}
