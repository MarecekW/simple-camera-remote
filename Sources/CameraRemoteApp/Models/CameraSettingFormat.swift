import CaptureCore
import SonyProtocol

/// How each camera setting the app shows or records is displayed — shared by
/// the inspector and the capture records, so both say the same thing.
enum CameraSettingFormat {
    /// The setting's value as the camera shows it, e.g. "1/60", "f/8.0", "MF".
    static func display(_ value: PTPValue, of code: SonyPropertyCode) -> String {
        formatters[code]?(value) ?? raw(value)
    }

    /// Whether the app offers `value` for `code` — e.g. not movie modes.
    static func isOffered(_ value: PTPValue, of code: SonyPropertyCode) -> Bool {
        offered[code]?(value) ?? true
    }

    /// The value as sent by the camera: hex for unsigned, decimal for signed.
    static func raw(_ value: PTPValue) -> String {
        switch value {
        case .signed(let number): String(number)
        case .unsigned(let number): "0x" + String(number, radix: 16, uppercase: true)
        case .string(let text): text
        }
    }

    /// What could make captures with these settings inconsistent.
    static func advisories(
        from properties: [SonyPropertyCode: PropertyDescriptor], mainsFrequency: Int,
        shootingType: Advisory.ShootingType, firstCapture: [CaptureRecord.Setting: String]?
    ) -> [Advisory] {
        let bits = { (code: SonyPropertyCode) in properties[code]?.currentValue.bitPattern }
        var settings = Advisory.Settings(mainsFrequency: mainsFrequency, shootingType: shootingType)
        settings.exposureMode = bits(.exposureProgramMode).map { ExposureMode(rawValue: $0) }
        settings.shutterSpeed = bits(.shutterSpeed).map { ShutterSpeed(rawValue: UInt32(truncatingIfNeeded: $0)) }
        settings.iso = bits(.isoSensitivity).map { ISOSensitivity(rawValue: UInt32(truncatingIfNeeded: $0)) }
        settings.whiteBalance = bits(.whiteBalance).map { WhiteBalanceMode(rawValue: $0) }
        settings.dynamicRangeOptimizer = bits(.dynamicRangeOptimizer).map { DynamicRangeOptimizer(rawValue: $0) }
        settings.imageSize = bits(.imageSize).map { ImageSize(rawValue: $0) }
        settings.jpegQuality = bits(.jpegQuality).map { JPEGQuality(rawValue: $0) }
        settings.rawCompression = bits(.rawCompression).map { RAWCompression(rawValue: $0) }
        settings.liveViewSettingEffect = bits(.liveViewSettingEffect).map { LiveViewSettingEffect(rawValue: $0) }
        settings.current = recordedSettings(from: properties).mapValues(\.display)
        settings.firstCapture = firstCapture
        return Advisory.check(settings)
    }

    /// The settings recorded with each capture, raw and as displayed.
    static func recordedSettings(
        from properties: [SonyPropertyCode: PropertyDescriptor]
    ) -> [CaptureRecord.Setting: CaptureRecord.SettingValue] {
        var settings: [CaptureRecord.Setting: CaptureRecord.SettingValue] = [:]
        for (setting, code) in recorded {
            guard let value = properties[code]?.currentValue else { continue }
            settings[setting] = CaptureRecord.SettingValue(raw: raw(value), display: display(value, of: code))
        }
        return settings
    }

    // MARK: - Private

    private static let recorded: [(CaptureRecord.Setting, SonyPropertyCode)] = [
        (.focalLength, .focalLength), (.aperture, .fNumber), (.shutterSpeed, .shutterSpeed),
        (.iso, .isoSensitivity), (.exposureCompensation, .exposureCompensation),
        (.exposureMode, .exposureProgramMode), (.whiteBalance, .whiteBalance),
        (.colorTemperature, .colorTemperature), (.focusMode, .focusMode), (.fileFormat, .fileFormat),
        (.jpegQuality, .jpegQuality), (.imageSize, .imageSize), (.aspectRatio, .aspectRatio),
        (.dynamicRangeOptimizer, .dynamicRangeOptimizer), (.rawCompression, .rawCompression),
        (.lensCompensationShading, .lensCompensationShading),
        (.lensCompensationChromaticAberration, .lensCompensationChromaticAberration),
        (.lensCompensationDistortion, .lensCompensationDistortion),
        (.driveMode, .driveMode),
    ]

    private typealias Describe = @Sendable (PTPValue) -> String

    private static let formatters: [SonyPropertyCode: Describe] = [
        .focalLength: { FocalLength(rawValue: UInt32(truncatingIfNeeded: $0.bitPattern ?? 0)).description },
        .fNumber: { Aperture(rawValue: UInt16(truncatingIfNeeded: $0.bitPattern ?? 0)).description },
        .shutterSpeed: { ShutterSpeed(rawValue: UInt32(truncatingIfNeeded: $0.bitPattern ?? 0)).description },
        .isoSensitivity: { ISOSensitivity(rawValue: UInt32(truncatingIfNeeded: $0.bitPattern ?? 0)).description },
        .exposureCompensation: {
            ExposureCompensation(rawValue: Int16(truncatingIfNeeded: $0.integerValue ?? 0)).description
        },
        // The camera reports 0 while white balance isn't set in kelvin.
        .colorTemperature: { $0.integerValue.map { $0 > 0 ? "\($0) K" : "—" } ?? "—" },
        .exposureProgramMode: label(ExposureMode.self),
        .whiteBalance: label(WhiteBalanceMode.self),
        .focusMode: label(FocusMode.self),
        .focusArea: label(FocusArea.self),
        .fileFormat: label(FileFormat.self),
        .jpegQuality: label(JPEGQuality.self),
        .imageSize: label(ImageSize.self),
        .aspectRatio: label(AspectRatio.self),
        .dynamicRangeOptimizer: label(DynamicRangeOptimizer.self),
        .lensCompensationShading: label(LensCompensation.self),
        .lensCompensationChromaticAberration: label(LensCompensation.self),
        .lensCompensationDistortion: label(LensCompensation.self),
        .rawCompression: label(RAWCompression.self),
    ]
    // Drive mode is shown raw: its bracketing values follow a bit pattern
    // (docs/PROPERTY_VALUES.md) that the app doesn't decode yet.

    private static let offered: [SonyPropertyCode: @Sendable (PTPValue) -> Bool] = [
        .exposureProgramMode: isOffered(ExposureMode.self)
    ]

    private static func label<Values: CameraValueSet>(_: Values.Type) -> Describe {
        { value in value.bitPattern.flatMap { Values(rawValue: $0)?.description } ?? raw(value) }
    }

    private static func isOffered<Values: CameraValueSet>(_: Values.Type) -> @Sendable (PTPValue) -> Bool {
        { value in value.bitPattern.flatMap { Values(rawValue: $0)?.isOffered } ?? true }
    }
}
