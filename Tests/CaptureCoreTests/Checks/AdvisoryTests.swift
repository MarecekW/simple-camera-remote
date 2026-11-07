import CaptureCore
import Testing

struct AdvisoryTests {
    /// 1/n s as the camera encodes it.
    private func shutter(_ denominator: UInt32) -> ShutterSpeed { ShutterSpeed(rawValue: 1 << 16 | denominator) }

    @Test func aConsistentSetupHasNone() {
        let settings = Advisory.Settings(
            exposureMode: .manual, shutterSpeed: shutter(50), iso: ISOSensitivity(rawValue: 100),
            whiteBalance: .colorTemperature, dynamicRangeOptimizer: .off)
        #expect(Advisory.check(settings).isEmpty)
    }

    @Test func flagsEveryAutomaticSetting() {
        let settings = Advisory.Settings(
            exposureMode: .programAuto, shutterSpeed: shutter(40), iso: .auto, whiteBalance: .auto,
            dynamicRangeOptimizer: DynamicRangeOptimizer(rawValue: 0x1F))
        #expect(
            Advisory.check(settings).map(\.kind) == [
                .automaticExposure, .flickerShutterSpeed, .autoISO, .autoWhiteBalance, .toneProcessing,
            ])
    }

    @Test(arguments: [
        (UInt32(100), 50, false), (50, 50, false), (25, 50, false), (40, 50, true), (200, 50, true),
        (60, 60, false), (120, 60, false), (100, 60, true),
    ])
    func flagsShutterSpeedsThatBand(denominator: UInt32, mains: Int, bands: Bool) {
        let settings = Advisory.Settings(shutterSpeed: shutter(denominator), mainsFrequency: mains)
        #expect(Advisory.check(settings).contains { $0.kind == .flickerShutterSpeed } == bands)
    }

    @Test func suggestsTheNearestSafeShutterSpeeds() {
        let message = Advisory.check(.init(shutterSpeed: shutter(40), mainsFrequency: 50)).first?.message
        #expect(message == "1/40 can band under mains lights (50 Hz) — use 1/50 or 1/25.")
        let fast = Advisory.check(.init(shutterSpeed: shutter(320), mainsFrequency: 50)).first?.message
        #expect(fast == "1/320 can band under mains lights (50 Hz) — use 1/100.")
    }

    @Test(arguments: [
        (Advisory.ShootingType.dataset, 5), (.product, 4), (.portrait, 1), (.off, 0),
    ])
    func eachShootingTypeKeepsItsAdvisories(type: Advisory.ShootingType, count: Int) {
        let settings = Advisory.Settings(
            exposureMode: .programAuto, shutterSpeed: shutter(40), iso: .auto, whiteBalance: .auto,
            dynamicRangeOptimizer: DynamicRangeOptimizer(rawValue: 0x1F), shootingType: type)
        #expect(Advisory.check(settings).count == count)
    }

    @Test func flagsReducedQualityForADataset() {
        let settings = Advisory.Settings(
            imageSize: ImageSize(rawValue: 2), jpegQuality: JPEGQuality(rawValue: 2), rawCompression: .compressed)
        #expect(Advisory.check(settings).map(\.kind) == [.reducedImageSize, .jpegQuality, .rawCompression])
        var product = settings
        product.shootingType = .product
        #expect(Advisory.check(product).isEmpty)
    }

    @Test func flagsSettingsThatChangedSinceTheFirstCapture() {
        var settings = Advisory.Settings()
        settings.firstCapture = [.focalLength: "35 mm", .aperture: "f/8.0", .colorTemperature: "5600 K"]
        settings.current = [.focalLength: "40 mm", .aperture: "f/8.0"]
        let advisories = Advisory.check(settings)
        #expect(advisories.map(\.setting) == [.focalLength])
        #expect(advisories.first?.message == "Focal length is 40 mm; the session's first capture had 35 mm.")
        settings.shootingType = .product
        #expect(Advisory.check(settings).isEmpty)
    }

    @Test(arguments: [
        (UInt32(100), "1/100 can band under mains lights (60 Hz) — use 1/60."),
        (50, "1/50 can band under mains lights (60 Hz) — use 1/60 or 1/40."),
        (125, "1/125 can band under mains lights (60 Hz) — use 1/60."),
    ])
    func suggestsSpeedsTheCameraHasAt60Hz(denominator: UInt32, message: String) {
        let advisory = Advisory.check(.init(shutterSpeed: shutter(denominator), mainsFrequency: 60)).first
        #expect(advisory?.message == message)
    }

    @Test func ignoresKelvinOutsideColourTemperature() {
        var settings = Advisory.Settings()
        settings.firstCapture = [.whiteBalance: "Color Temperature", .colorTemperature: "5500 K"]
        settings.current = [.whiteBalance: "Daylight", .colorTemperature: "—"]
        #expect(Advisory.check(settings).map(\.setting) == [.whiteBalance])
        settings.current = [.whiteBalance: "Color Temperature", .colorTemperature: "5600 K"]
        #expect(Advisory.check(settings).map(\.setting) == [.colorTemperature])
    }

    @Test func flagsALiveViewThatDoesntShowTheExposureForADataset() {
        var settings = Advisory.Settings(liveViewSettingEffect: .off)
        let advisory = Advisory.check(settings).first
        #expect(advisory?.kind == .liveViewSettingEffectOff)
        #expect(advisory?.setting == nil)
        #expect(
            advisory?.message
                == "Live view isn't showing the exposure — turn on Live View Display › Setting Effect on the camera, "
                + "so the preview and histogram match the shot.")
        settings.liveViewSettingEffect = .on
        #expect(Advisory.check(settings).isEmpty)
        for type in [Advisory.ShootingType.product, .portrait, .off] {
            #expect(Advisory.check(.init(liveViewSettingEffect: .off, shootingType: type)).isEmpty)
        }
    }
}
