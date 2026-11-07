import Testing

@testable import CaptureCore

/// Raw values are ones the A6700 reported (docs/HARDWARE_NOTES.md).
struct CameraValueTests {
    @Test(arguments: [
        (UInt32(0x0001_03E8), "1/1000"),
        (0x0001_003C, "1/60"),
        (0x0019_000A, "2.5″"),
        (0x012C_000A, "30″"),
        (0x0004_000A, "0.4″"),
        (0, "BULB"),
        (0xFFFF_FFFF, "—"),  // the camera's "no value"
    ])
    func describesShutterSpeeds(raw: UInt32, expected: String) {
        #expect(ShutterSpeed(rawValue: raw).description == expected)
    }

    @Test func shutterSpeedSeconds() {
        #expect(ShutterSpeed(rawValue: 0x0001_00FA).seconds == 1.0 / 250)
        #expect(ShutterSpeed.bulb.seconds == nil)
    }

    @Test(arguments: [(UInt16(400), "f/4.0"), (710, "f/7.1"), (1100, "f/11"), (2200, "f/22"), (0xFFFE, "—")])
    func describesApertures(raw: UInt16, expected: String) {
        #expect(Aperture(rawValue: raw).description == expected)
    }

    @Test(arguments: [
        (UInt32(0x00FF_FFFF), "AUTO"),
        (100, "100"),
        (0x1000_0032, "L50"),  // extended low ISO, listed by the A6700
        (0x0100_0320, "MFNR 800"),
    ])
    func describesISOSensitivities(raw: UInt32, expected: String) {
        #expect(ISOSensitivity(rawValue: raw).description == expected)
    }

    @Test func isoAutoHasNoValue() {
        #expect(ISOSensitivity.auto.isAuto)
        #expect(ISOSensitivity.auto.value == nil)
        #expect(ISOSensitivity(rawValue: 0x1000_0032).value == 50)
    }

    @Test(arguments: [(Int16(0), "±0.0"), (1300, "+1.3"), (-700, "−0.7"), (5000, "+5.0")])
    func describesExposureCompensation(raw: Int16, expected: String) {
        #expect(ExposureCompensation(rawValue: raw).description == expected)
    }

    @Test func describesFocalLengths() {
        #expect(FocalLength(rawValue: 37_000).description == "37 mm")
        #expect(FocalLength(rawValue: 37_500).description == "37.5 mm")
        #expect(FocalLength(rawValue: 18_000) < FocalLength(rawValue: 105_000))
    }

    @Test func labelsKnownModesAndKeepsUnknownOnes() {
        #expect(ExposureMode(rawValue: 0x1).description == "M")
        #expect(FocusMode(rawValue: 0x8004) == .continuousAF)
        #expect(WhiteBalanceMode.colorTemperature.description == "Color Temperature")
        #expect(FileFormat(rawValue: 2) == .rawAndJPEG)
        #expect(ExposureMode(rawValue: 0x5_8011).description == "SCN: Sports Action")
        #expect(ExposureMode(rawValue: 0x5_8099).description == "0x58099")
    }

    @Test func offersStillModesOnly() {
        #expect(ExposureMode.manual.isOffered)
        #expect(ExposureMode(rawValue: 0x5_8011).isOffered)
        #expect(!ExposureMode(rawValue: 0x7_8050).isOffered)  // movie P
        #expect(!ExposureMode(rawValue: 0x9_805D).isOffered)  // S&Q AUTO
        #expect(!ExposureMode(rawValue: 0xC_8093).isOffered)  // interval movie P
    }

    @Test func labelTablesHaveNoDuplicates() {
        #expect(Set(ExposureMode.labels.map(\.value)).count == ExposureMode.labels.count)
        #expect(Set(FocusMode.labels.map(\.value)).count == FocusMode.labels.count)
        #expect(Set(WhiteBalanceMode.labels.map(\.value)).count == WhiteBalanceMode.labels.count)
        #expect(Set(FileFormat.labels.map(\.value)).count == FileFormat.labels.count)
    }
}
