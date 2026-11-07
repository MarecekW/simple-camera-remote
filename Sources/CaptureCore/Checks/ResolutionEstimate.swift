import Foundation

/// How many pixels per millimetre the subject gets, for planning the rig —
/// an estimate from the thin-lens model, not a measurement.  The exact
/// scale is measured on a shot of a known length (`MeasuredScale`).
///
/// The distance is measured from the sensor-plane mark ⦵ on the body to the
/// subject, since the camera can't report its focus distance.
public struct ResolutionEstimate: Equatable, Sendable {
    /// The camera's sensor and its full-resolution image.
    public struct Sensor: Equatable, Sendable {
        /// Millimetres.
        public var width: Double
        public var height: Double
        /// Pixels at full size (L, 3:2).
        public var pixelsAcross: Int
        public var pixelsDown: Int

        public init(width: Double, height: Double, pixelsAcross: Int, pixelsDown: Int) {
            self.width = width
            self.height = height
            self.pixelsAcross = pixelsAcross
            self.pixelsDown = pixelsDown
        }

        /// The A6700's APS-C sensor: 23.3 × 15.5 mm, 6192 × 4128 at L.
        public static let a6700 = Sensor(width: 23.3, height: 15.5, pixelsAcross: 6192, pixelsDown: 4128)
    }

    /// An image size's width as a fraction of L's: the A6700 records 6192,
    /// 4384 and 3104 px across at L, M and S (3:2).
    public static func sizeScale(of size: ImageSize) -> Double {
        switch size {
        case .medium: 4384.0 / 6192
        case .small: 3104.0 / 6192
        default: 1
        }
    }

    /// Millimetres.
    public let focalLength: Double
    /// Millimetres, from the sensor plane to the subject.
    public let distance: Double
    public let sensor: Sensor
    /// The image's width as a fraction of full size (L 1, M ≈ 0.71, S 0.5).
    public let sizeScale: Double

    /// Nil when the subject is too close to be focused at this focal length
    /// (the thin-lens model needs at least four focal lengths).
    public init?(focalLength: Double, distance: Double, sensor: Sensor = .a6700, sizeScale: Double = 1) {
        guard focalLength > 0, distance >= 4 * focalLength, sizeScale > 0 else { return nil }
        self.focalLength = focalLength
        self.distance = distance
        self.sensor = sensor
        self.sizeScale = sizeScale
    }

    /// Image size on the sensor over subject size.  With the subject at u
    /// and the image at v from the lens, 1/f = 1/u + 1/v and u + v = the
    /// distance, so u = (D + √(D² − 4fD)) / 2 and m = v / u.
    public var magnification: Double {
        let objectDistance = (distance + (distance * distance - 4 * focalLength * distance).squareRoot()) / 2
        return (distance - objectDistance) / objectDistance
    }

    /// Image pixels per millimetre of subject, at the chosen image size.
    public var pixelsPerMillimetre: Double {
        magnification * Double(sensor.pixelsAcross) * sizeScale / sensor.width
    }

    /// The subject area the full 3:2 frame covers, in millimetres.
    public var fieldOfView: (width: Double, height: Double) {
        (sensor.width / magnification, sensor.height / magnification)
    }

    /// How many image pixels a feature of `millimetres` spans.
    public func pixels(forFeature millimetres: Double) -> Double {
        millimetres * pixelsPerMillimetre
    }

    /// The farthest distance (sensor plane to subject, millimetres) that
    /// still gives `pixelsPerMillimetre` at `focalLength`; nil for values
    /// that can't be met (zero, negative or infinite).
    public static func maximumDistance(
        focalLength: Double, pixelsPerMillimetre: Double, sensor: Sensor = .a6700, sizeScale: Double = 1
    ) -> Double? {
        guard focalLength > 0, pixelsPerMillimetre > 0, pixelsPerMillimetre.isFinite, sizeScale > 0 else {
            return nil
        }
        let magnification = pixelsPerMillimetre * sensor.width / (Double(sensor.pixelsAcross) * sizeScale)
        // u = f(1 + 1/m) and v = f(1 + m).
        return focalLength * (2 + magnification + 1 / magnification)
    }
}
