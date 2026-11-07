import Foundation

// Exposure values decoded from Sony's wire encodings (docs/HARDWARE_NOTES.md).
// Each keeps its raw value, so a value the camera sends always round-trips
// even when it can't be described.

/// Shutter speed: numerator in the high 16 bits, denominator in the low —
/// `1/1000` is `0x0001_03E8`, 2.5 s is `0x0019_000A`.
public struct ShutterSpeed: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let bulb = ShutterSpeed(rawValue: 0)

    private var numerator: UInt32 { rawValue >> 16 }
    private var denominator: UInt32 { rawValue & 0xFFFF }

    /// Exposure time in seconds; nil for bulb and for the camera's "no
    /// value" marker (`0xFFFF_FFFF`).
    public var seconds: Double? {
        guard rawValue != 0xFFFF_FFFF, numerator > 0, denominator > 0 else { return nil }
        return Double(numerator) / Double(denominator)
    }

    /// As the camera shows it: "1/1000" for fractions, "0.4″" and "2.5″" for
    /// times given in tenths, "BULB".
    public var description: String {
        if self == .bulb { return "BULB" }
        guard let seconds else { return "—" }
        if numerator == 1 { return "1/\(denominator)" }
        return "\(Self.trimmed(seconds))″"
    }

    /// One decimal, dropped when it's zero: 2.5, 30.
    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}

/// Aperture as f-number × 100 (`400` = f/4).
public struct Aperture: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// The f-number; nil for the camera's "no lens" / "iris closed" markers
    /// (`0xFFFD`…`0xFFFF`).
    public var fNumber: Double? {
        rawValue < 0xFFFD && rawValue > 0 ? Double(rawValue) / 100 : nil
    }

    /// "f/4.0", "f/7.1", "f/11".
    public var description: String {
        guard let fNumber else { return "—" }
        return fNumber < 10 ? String(format: "f/%.1f", fNumber) : String(format: "f/%.0f", fNumber)
    }
}

/// ISO: value in the low 24 bits (`0xFFFFFF` = auto); bits 28–31 flag the
/// extended range (shown as "L" below ISO 100), bits 24–27 the multi-frame
/// noise-reduction modes.
public struct ISOSensitivity: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let auto = ISOSensitivity(rawValue: 0x00FF_FFFF)

    public var isAuto: Bool { rawValue & 0x00FF_FFFF == 0x00FF_FFFF }
    /// Outside the sensor's native range.
    public var isExtended: Bool { rawValue >> 28 != 0 }
    public var isMultiFrameNoiseReduction: Bool { (rawValue >> 24) & 0xF != 0 }
    public var value: UInt32? { isAuto ? nil : rawValue & 0x00FF_FFFF }

    /// "AUTO", "100", "L50" for an extended value, "MFNR 800".
    public var description: String {
        guard let value else { return isMultiFrameNoiseReduction ? "MFNR AUTO" : "AUTO" }
        let number = (isExtended && value < 100 ? "L" : "") + String(value)
        return isMultiFrameNoiseReduction ? "MFNR \(number)" : number
    }
}

/// Exposure compensation in thousandths of a stop (`-1000` = −1 EV).
public struct ExposureCompensation: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int16
    public init(rawValue: Int16) { self.rawValue = rawValue }

    public var stops: Double { Double(rawValue) / 1000 }

    /// "0.0", "+1.3", "−0.7" (with a real minus sign).
    public var description: String {
        guard rawValue != 0 else { return "±0.0" }
        return (rawValue > 0 ? "+" : "−") + String(format: "%.1f", abs(stops))
    }
}
