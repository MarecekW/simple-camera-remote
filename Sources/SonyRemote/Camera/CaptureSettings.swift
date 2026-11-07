import SonyProtocol

/// A setting that would make a capture miss its files or its purpose.
public struct CaptureSettingIssue: Equatable, Sendable {
    public let code: SonyPropertyCode
    /// What's wrong, for the user.
    public let message: String
    /// The value that fixes it.
    public let requiredValue: PTPValue
    /// Whether the camera accepts that value right now; otherwise it has to
    /// be changed on the camera (e.g. a dial owns it).
    public let isFixable: Bool
}

/// The settings every capture depends on: RAW and JPEG, full size, saved to
/// the Mac and the card, optical zoom only, one picture
/// per press.  Wire values are from the A6700 (docs/HARDWARE_NOTES.md,
/// docs/PROPERTY_VALUES.md).
public enum CaptureSettings {
    private struct Requirement {
        let code: SonyPropertyCode
        let value: PTPValue
        let message: String
    }

    /// In the order they must land: the camera only offers some values once
    /// an earlier setting has them (RAW+JPEG sent to the Mac needs RAW+JPEG
    /// recorded).
    private static let requirements = [
        Requirement(code: .fileFormat, value: .unsigned(2), message: "The camera must record RAW+JPEG."),
        Requirement(code: .pcSaveImage, value: .unsigned(1), message: "Both RAW and JPEG must be sent to the Mac."),
        Requirement(code: .pcSaveImageSize, value: .unsigned(1), message: "Images must reach the Mac at full size."),
        Requirement(
            code: .stillImageStoreDestination, value: .unsigned(0x11),
            message: "Images must be saved to the Mac and the card."),
        Requirement(
            code: .compressionFileFormat, value: .unsigned(1), message: "The second file must be a JPEG, not HEIF."),
        Requirement(
            code: .zoomSetting, value: .unsigned(1),
            message: "Zoom must be optical only, so no image is digitally zoomed."),
        // A capture expects one set of files per press; continuous, bracket
        // and self-timer modes would send more, or late.  0x1 is Single
        // Shooting, verified on the A6700 (docs/PROPERTY_VALUES.md).
        Requirement(
            code: .driveMode, value: .unsigned(1),
            message: "Drive mode must be Single Shooting, so each press takes one picture."),
    ]

    /// Settings that are wrong in `properties`.  Settings the camera doesn't
    /// report are skipped.
    public static func issues(in properties: [SonyPropertyCode: PropertyDescriptor]) -> [CaptureSettingIssue] {
        requirements.compactMap { requirement in
            guard let descriptor = properties[requirement.code], descriptor.currentValue != requirement.value else {
                return nil
            }
            return CaptureSettingIssue(
                code: requirement.code,
                message: requirement.message,
                requiredValue: requirement.value,
                isFixable: descriptor.accepts(requirement.value)
            )
        }
    }

    /// How many files a capture sends to the Mac with these settings.
    public static func expectedFileCount(in properties: [SonyPropertyCode: PropertyDescriptor]) -> Int {
        let recordsBoth = properties[.fileFormat]?.currentValue == .unsigned(2)
        let sendsBoth = properties[.pcSaveImage]?.currentValue == .unsigned(1)
        return recordsBoth && sendsBoth ? 2 : 1
    }
}

extension PropertyDescriptor {
    /// Whether the camera accepts `value` right now: in its list of values
    /// settable now, or on a step of its range.  A property without either
    /// says nothing about what it takes, so nothing is accepted — an
    /// unsupported value once crashed the A6700.  (Only string properties
    /// come without one, and the app sets none of them.)
    public func accepts(_ value: PTPValue) -> Bool {
        guard isWritable, availability == .enabled else { return false }
        switch constraint {
        case .enumeration(let settable, _): return settable.contains(value)
        case .range(let minimum, let maximum, let step):
            guard let number = value.integerValue, let low = minimum.integerValue, let high = maximum.integerValue,
                let increment = step.integerValue, (low...high).contains(number)
            else { return false }
            // A step below 1 means no step, as the inspector's choices read it.
            let (offset, overflow) = number.subtractingReportingOverflow(low)
            return !overflow && offset % max(increment, 1) == 0
        case .none: return false
        }
    }
}
