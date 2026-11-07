import Foundation

// Value sets of camera settings, as open structs like the protocol's codes:
// the camera may send a value these tables don't name (firmware updates add
// modes), and it must still round-trip.  Wire values are from the A6700's
// own lists (docs/HARDWARE_NOTES.md) and libgphoto2.

/// A camera setting's value, with labels for the values the app knows.
public protocol CameraValueSet: RawRepresentable, Hashable, Sendable, CustomStringConvertible
where RawValue == UInt64 {
    /// Known values and their labels.
    static var labels: [(value: Self, label: String)] { get }
    /// Whether a stills app offers this value (e.g. not movie modes).
    var isOffered: Bool { get }
}

extension CameraValueSet {
    public var isOffered: Bool { true }

    public var description: String {
        Self.labels.first { $0.value == self }?.label ?? String(format: "0x%llX", rawValue)
    }
}

/// Exposure program mode, `0x500E`.
public struct ExposureMode: CameraValueSet {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let manual = Self(rawValue: 0x0_0001)
    public static let programAuto = Self(rawValue: 0x1_0002)
    public static let aperturePriority = Self(rawValue: 0x2_0003)
    public static let shutterPriority = Self(rawValue: 0x3_0004)
    public static let intelligentAuto = Self(rawValue: 0x4_8000)

    // Names from docs/PROPERTY_VALUES.md (libgphoto2, checked against the
    // A6700's list).
    public static let labels: [(value: Self, label: String)] = [
        (.intelligentAuto, "AUTO"), (.programAuto, "P"), (.aperturePriority, "A"), (.shutterPriority, "S"),
        (.manual, "M"), (Self(rawValue: 0x0_0007), "SCN: Portrait"), (Self(rawValue: 0x5_8011), "SCN: Sports Action"),
        (Self(rawValue: 0x5_8012), "SCN: Sunset"), (Self(rawValue: 0x5_8013), "SCN: Night Scene"),
        (Self(rawValue: 0x5_8014), "SCN: Landscape"), (Self(rawValue: 0x5_8015), "SCN: Macro"),
        (Self(rawValue: 0x5_8017), "SCN: Night Portrait"),
    ]

    /// Bits 16–19 are the mode's category; 7–C are movie, S&Q and interval
    /// movie modes, which a stills app doesn't offer.
    public var isOffered: Bool { !(0x7...0xC).contains((rawValue >> 16) & 0xF) }
}

/// Focus mode, `0x500A`.
public struct FocusMode: CameraValueSet {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let manual = Self(rawValue: 0x0001)
    public static let singleAF = Self(rawValue: 0x0002)
    public static let continuousAF = Self(rawValue: 0x8004)
    public static let automaticAF = Self(rawValue: 0x8005)
    public static let directManual = Self(rawValue: 0x8006)

    public static let labels: [(value: Self, label: String)] = [
        (.singleAF, "AF-S"), (.automaticAF, "AF-A"), (.continuousAF, "AF-C"), (.directManual, "DMF"),
        (.manual, "MF"),
    ]
}

/// Focus area, `0xD22C` (docs/PROPERTY_VALUES.md), named as the A6700's
/// menu names them.
public struct FocusArea: CameraValueSet {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let labels: [(value: Self, label: String)] = [
        (Self(rawValue: 0x001), "Wide"), (Self(rawValue: 0x002), "Zone"), (Self(rawValue: 0x003), "Center Fix"),
        (Self(rawValue: 0x101), "Spot S"), (Self(rawValue: 0x102), "Spot M"), (Self(rawValue: 0x103), "Spot L"),
        (Self(rawValue: 0x104), "Expand Spot"), (Self(rawValue: 0x201), "Tracking: Wide"),
        (Self(rawValue: 0x202), "Tracking: Zone"), (Self(rawValue: 0x203), "Tracking: Center Fix"),
        (Self(rawValue: 0x204), "Tracking: Spot S"), (Self(rawValue: 0x205), "Tracking: Spot M"),
        (Self(rawValue: 0x206), "Tracking: Spot L"), (Self(rawValue: 0x207), "Tracking: Expand Spot"),
    ]
}

/// White balance, `0x5005`.
public struct WhiteBalanceMode: CameraValueSet {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let auto = Self(rawValue: 0x0002)
    public static let daylight = Self(rawValue: 0x0004)
    public static let incandescent = Self(rawValue: 0x0006)
    public static let flash = Self(rawValue: 0x0007)
    public static let fluorescentWarmWhite = Self(rawValue: 0x8001)
    public static let fluorescentCoolWhite = Self(rawValue: 0x8002)
    public static let fluorescentDayWhite = Self(rawValue: 0x8003)
    public static let fluorescentDaylight = Self(rawValue: 0x8004)
    public static let cloudy = Self(rawValue: 0x8010)
    public static let shade = Self(rawValue: 0x8011)
    /// Kelvin set with `0xD20F`.
    public static let colorTemperature = Self(rawValue: 0x8012)
    public static let custom1 = Self(rawValue: 0x8020)
    public static let custom2 = Self(rawValue: 0x8021)
    public static let custom3 = Self(rawValue: 0x8022)
    public static let underwaterAuto = Self(rawValue: 0x8030)

    public static let labels: [(value: Self, label: String)] = [
        (.auto, "Auto"), (.daylight, "Daylight"), (.shade, "Shade"), (.cloudy, "Cloudy"),
        (.incandescent, "Incandescent"), (.fluorescentWarmWhite, "Fluorescent: Warm White"),
        (.fluorescentCoolWhite, "Fluorescent: Cool White"), (.fluorescentDayWhite, "Fluorescent: Day White"),
        (.fluorescentDaylight, "Fluorescent: Daylight"), (.flash, "Flash"), (.underwaterAuto, "Underwater Auto"),
        (.colorTemperature, "Color Temperature"), (.custom1, "Custom 1"), (.custom2, "Custom 2"),
        (.custom3, "Custom 3"),
    ]
}

/// The format recorded to the card, `0xD253`.
public struct FileFormat: CameraValueSet {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let raw = Self(rawValue: 1)
    public static let rawAndJPEG = Self(rawValue: 2)
    public static let jpeg = Self(rawValue: 3)

    public static let labels: [(value: Self, label: String)] = [
        (.raw, "RAW"), (.rawAndJPEG, "RAW+JPEG"), (.jpeg, "JPEG"),
    ]
}

/// JPEG quality, `0xD252`.
public struct JPEGQuality: CameraValueSet {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let extraFine = Self(rawValue: 1)

    public static let labels: [(value: Self, label: String)] = [
        (.extraFine, "Extra Fine"), (Self(rawValue: 2), "Fine"), (Self(rawValue: 3), "Standard"),
        (Self(rawValue: 4), "Light"),
    ]
}

/// JPEG image size, `0xD203`.
public struct ImageSize: CameraValueSet {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// The sensor's full resolution.
    public static let large = Self(rawValue: 1)
    public static let medium = Self(rawValue: 2)
    public static let small = Self(rawValue: 3)

    public static let labels: [(value: Self, label: String)] = [
        (.large, "L"), (.medium, "M"), (.small, "S"),
    ]
}

/// Aspect ratio, `0xD211`.
public struct AspectRatio: CameraValueSet {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let labels: [(value: Self, label: String)] = [
        (Self(rawValue: 1), "3:2"), (Self(rawValue: 2), "16:9"), (Self(rawValue: 3), "4:3"),
        (Self(rawValue: 4), "1:1"),
    ]
}

/// Dynamic range optimizer, `0xD201` — anything but off alters the JPEG.
public struct DynamicRangeOptimizer: CameraValueSet {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let off = Self(rawValue: 0x01)

    public static let labels: [(value: Self, label: String)] = [
        (.off, "Off"), (Self(rawValue: 0x1F), "DRO Auto"), (Self(rawValue: 0x11), "DRO Lv1"),
        (Self(rawValue: 0x12), "DRO Lv2"), (Self(rawValue: 0x13), "DRO Lv3"), (Self(rawValue: 0x14), "DRO Lv4"),
        (Self(rawValue: 0x15), "DRO Lv5"),
    ]
}

/// RAW compression, `0xD288` (the A6700 has no uncompressed RAW).  Value 1
/// is verified on files; 6 is the only other option the camera lists.
public struct RAWCompression: CameraValueSet {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let compressed = Self(rawValue: 1)
    public static let losslessCompressed = Self(rawValue: 6)

    public static let labels: [(value: Self, label: String)] = [
        (.compressed, "Compressed"), (.losslessCompressed, "Lossless Compressed"),
    ]
}

/// In-camera lens compensation (shading `0xD1A2`, chromatic aberration
/// `0xD1A3`, distortion `0xD1A4`); applied to the JPEG only.
public struct LensCompensation: CameraValueSet {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let labels: [(value: Self, label: String)] = [
        (Self(rawValue: 1), "Off"), (Self(rawValue: 2), "Auto"), (Self(rawValue: 3), "Low"),
    ]
}

/// Live View Display › Setting Effect, `0xD231`: whether live view shows the
/// exposure settings' effect.  Only read, never set (docs/PROPERTY_VALUES.md).
public struct LiveViewSettingEffect: CameraValueSet {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let on = Self(rawValue: 1)
    public static let off = Self(rawValue: 2)

    public static let labels: [(value: Self, label: String)] = [(.on, "On"), (.off, "Off")]
}
