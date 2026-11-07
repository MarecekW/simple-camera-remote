/// A setting that works but may make a dataset inconsistent — shown next to
/// the setting and recorded with each capture, never blocking the shutter.
/// (Settings that would make a capture wrong block it instead: see
/// `CaptureSettings` in SonyRemote.)
public struct Advisory: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Exposure mode other than M.
        case automaticExposure
        case autoISO
        /// A shutter speed that mains-powered lights can band at.
        case flickerShutterSpeed
        case autoWhiteBalance
        /// DRO or other in-camera tone changes.
        case toneProcessing
        /// An image size below the sensor's full resolution.
        case reducedImageSize
        /// JPEG compressed more than Extra Fine.
        case jpegQuality
        /// Lossy RAW compression.
        case rawCompression
        /// A setting that differs from the session's first capture.
        case changedSinceFirstCapture
        /// Live view not showing the exposure settings' effect: the preview
        /// and its histogram don't match the shot.
        case liveViewSettingEffectOff
    }

    public let kind: Kind
    public let message: String
    /// The setting it's about, where it's about one (shown on its row).
    public let setting: CaptureRecord.Setting?

    public init(kind: Kind, message: String, setting: CaptureRecord.Setting? = nil) {
        self.kind = kind
        self.message = message
        self.setting = setting
    }

    /// What the photos are for, which decides what's worth pointing out.
    public enum ShootingType: String, Sendable, CaseIterable {
        /// Scientific data, e.g. a training set: everything must match
        /// from shot to shot, at full quality.
        case dataset
        /// Catalogue shots: consistent exposure and colour; tone processing,
        /// quality and changes between shots are style choices.
        case product
        /// People: settings vary on purpose; only the lights still matter.
        case portrait
        /// No advisories.
        case off

        /// The advisories this type of work cares about.
        public var kinds: Set<Kind> {
            switch self {
            case .dataset: Set(Kind.allCases)
            case .product: [.automaticExposure, .autoISO, .flickerShutterSpeed, .autoWhiteBalance]
            case .portrait: [.flickerShutterSpeed]
            case .off: []
            }
        }
    }

    /// The settings the rules look at; nil where the camera doesn't say.
    public struct Settings: Equatable, Sendable {
        public var exposureMode: ExposureMode?
        public var shutterSpeed: ShutterSpeed?
        public var iso: ISOSensitivity?
        public var whiteBalance: WhiteBalanceMode?
        public var dynamicRangeOptimizer: DynamicRangeOptimizer?
        public var imageSize: ImageSize?
        public var jpegQuality: JPEGQuality?
        public var rawCompression: RAWCompression?
        public var liveViewSettingEffect: LiveViewSettingEffect?
        /// The local mains frequency in hertz (50 or 60): lights flicker at
        /// twice it.
        public var mainsFrequency: Int
        public var shootingType: ShootingType
        /// The settings now and in the session's first capture, as displayed
        /// (nil before the first capture), for spotting what changed.
        public var current: [CaptureRecord.Setting: String] = [:]
        public var firstCapture: [CaptureRecord.Setting: String]?

        public init(
            exposureMode: ExposureMode? = nil, shutterSpeed: ShutterSpeed? = nil, iso: ISOSensitivity? = nil,
            whiteBalance: WhiteBalanceMode? = nil, dynamicRangeOptimizer: DynamicRangeOptimizer? = nil,
            imageSize: ImageSize? = nil, jpegQuality: JPEGQuality? = nil, rawCompression: RAWCompression? = nil,
            liveViewSettingEffect: LiveViewSettingEffect? = nil, mainsFrequency: Int = 50,
            shootingType: ShootingType = .dataset
        ) {
            self.exposureMode = exposureMode
            self.shutterSpeed = shutterSpeed
            self.iso = iso
            self.whiteBalance = whiteBalance
            self.dynamicRangeOptimizer = dynamicRangeOptimizer
            self.imageSize = imageSize
            self.jpegQuality = jpegQuality
            self.rawCompression = rawCompression
            self.liveViewSettingEffect = liveViewSettingEffect
            self.mainsFrequency = mainsFrequency
            self.shootingType = shootingType
        }
    }

    /// The advisories for `settings` that its shooting type cares about, in
    /// the order of the inspector.
    public static func check(_ settings: Settings) -> [Advisory] {
        let wanted = settings.shootingType.kinds
        return allAdvisories(settings).filter { wanted.contains($0.kind) }
    }

    private static func allAdvisories(_ settings: Settings) -> [Advisory] {
        var advisories: [Advisory] = []
        if let mode = settings.exposureMode, mode != .manual {
            advisories.append(
                Advisory(
                    kind: .automaticExposure,
                    message: "\(mode) sets exposure per shot — use M so every capture is exposed the same.",
                    setting: .exposureMode))
        }
        if let message = flickerMessage(settings.shutterSpeed, mainsFrequency: settings.mainsFrequency) {
            advisories.append(Advisory(kind: .flickerShutterSpeed, message: message, setting: .shutterSpeed))
        }
        if settings.iso?.isAuto == true {
            advisories.append(
                Advisory(
                    kind: .autoISO, message: "Auto ISO lets brightness and noise vary — set a fixed ISO.", setting: .iso
                ))
        }
        if settings.whiteBalance == .auto {
            advisories.append(
                Advisory(
                    kind: .autoWhiteBalance,
                    message: "Auto white balance shifts colour between shots — set a kelvin value.",
                    setting: .whiteBalance))
        }
        if let dro = settings.dynamicRangeOptimizer, dro != .off {
            advisories.append(
                Advisory(
                    kind: .toneProcessing, message: "\(dro) changes the JPEG's tones from shot to shot — turn it off.",
                    setting: .dynamicRangeOptimizer))
        }
        if let size = settings.imageSize, size != .large {
            advisories.append(
                Advisory(
                    kind: .reducedImageSize, message: "Size \(size) records fewer pixels than the sensor has — use L.",
                    setting: .imageSize))
        }
        if let quality = settings.jpegQuality, quality != .extraFine {
            advisories.append(
                Advisory(
                    kind: .jpegQuality, message: "JPEG \(quality) compresses more than Extra Fine — use Extra Fine.",
                    setting: .jpegQuality))
        }
        if settings.rawCompression == .compressed {
            advisories.append(
                Advisory(
                    kind: .rawCompression, message: "Compressed RAW loses some data — use Lossless Compressed.",
                    setting: .rawCompression))
        }
        if settings.liveViewSettingEffect == .off {
            advisories.append(
                Advisory(
                    kind: .liveViewSettingEffectOff,
                    message: "Live view isn't showing the exposure — turn on Live View Display › Setting Effect "
                        + "on the camera, so the preview and histogram match the shot."))
        }
        if let first = settings.firstCapture {
            for setting in driftSettings {
                guard let then = first[setting], let now = settings.current[setting], then != now else { continue }
                // Kelvin only matters while white balance is set in kelvin on
                // both sides; a change of white balance is flagged on its own.
                if setting == .colorTemperature,
                    then == Self.noValue || now == Self.noValue
                        || first[.whiteBalance] != settings.current[.whiteBalance]
                {
                    continue
                }
                advisories.append(
                    Advisory(
                        kind: .changedSinceFirstCapture,
                        message: "\(setting.label) is \(now); the session's first capture had \(then).",
                        setting: setting))
            }
        }
        return advisories
    }

    /// How a setting without a value is displayed (e.g. kelvin outside
    /// colour-temperature white balance).
    private static let noValue = "—"

    /// Settings that change the picture, so they should stay as they were
    /// for the session's first capture.
    private static let driftSettings: [CaptureRecord.Setting] = [
        .focalLength, .exposureMode, .aperture, .shutterSpeed, .iso, .exposureCompensation, .whiteBalance,
        .colorTemperature, .imageSize, .aspectRatio, .dynamicRangeOptimizer, .lensCompensationShading,
        .lensCompensationChromaticAberration, .lensCompensationDistortion,
    ]

    /// Lights on mains flicker at twice its frequency; an exposure lasting a
    /// whole number of flicker periods sees the same light whenever it starts.
    static func flickerMessage(_ shutterSpeed: ShutterSpeed?, mainsFrequency: Int) -> String? {
        guard let shutterSpeed, let seconds = shutterSpeed.seconds, mainsFrequency > 0 else { return nil }
        let flicker = Double(2 * mainsFrequency)
        let periods = seconds * flicker
        guard abs(periods - periods.rounded()) > 0.02 || periods.rounded() < 1 else { return nil }
        // Suggest the nearest safe speeds a camera offers, shorter and longer.
        let isSafe = { (candidate: Double) in
            let candidatePeriods = candidate * flicker
            return candidatePeriods.rounded() >= 1 && abs(candidatePeriods - candidatePeriods.rounded()) <= 0.02
        }
        let safe = standardShutterSpeeds.filter(isSafe)
        let suggestions = [safe.last { $0 < seconds }, safe.first { $0 > seconds }].compactMap { $0 }
            .map(Self.shutterText(seconds:))
        return "\(shutterSpeed) can band under mains lights (\(mainsFrequency) Hz) — use "
            + suggestions.joined(separator: " or ") + "."
    }

    /// The camera's shutter speeds in third stops from 1/8000 s to 30 s, in
    /// seconds, shortest first.
    private static let standardShutterSpeeds: [Double] =
        [
            8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500, 400, 320, 250, 200, 160, 125,
            100, 80, 60, 50, 40, 30, 25, 20, 15, 13, 10, 8, 6, 5, 4, 3,
        ].map { 1 / $0 } + [0.4, 0.5, 0.6, 0.8, 1, 1.3, 1.6, 2, 2.5, 3.2, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30]

    /// "1/100", "1/50", "1/25", or seconds for longer times.
    private static func shutterText(seconds: Double) -> String {
        let reciprocal = 1 / seconds
        if reciprocal >= 1, abs(reciprocal - reciprocal.rounded()) < 0.01 { return "1/\(Int(reciprocal.rounded()))" }
        return seconds.formatted(.number.precision(.fractionLength(0...2))) + " s"
    }
}
