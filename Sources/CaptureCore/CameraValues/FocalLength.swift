import Foundation

/// Focal length in thousandths of a millimetre, as the camera reports it.
/// The A6700 with the SELP18105G reports whole millimetres.
public struct FocalLength: RawRepresentable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public var millimetres: Double { Double(rawValue) / 1000 }

    /// "37 mm", or "37.5 mm" when the camera reports a fraction.
    public var description: String {
        rawValue % 1000 == 0 ? "\(rawValue / 1000) mm" : String(format: "%.1f mm", millimetres)
    }

    public static func < (lhs: FocalLength, rhs: FocalLength) -> Bool { lhs.rawValue < rhs.rawValue }
}
