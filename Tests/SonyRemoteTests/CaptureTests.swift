import CameraFixtures
import Foundation
import Testing

@testable import SonyProtocol
@testable import SonyRemote

@MainActor
struct CaptureSettingsTests {
    /// The recorded A6700 sent only JPEGs to the Mac (it was in AF-C, which
    /// is allowed: captures wait for focus).
    @Test func flagsTheRecordedCamerasWrongSettings() throws {
        let properties = try recordedProperties()
        let issues = CaptureSettings.issues(in: properties)
        #expect(issues.map(\.code) == [.pcSaveImage])
        #expect(issues.allSatisfy { $0.isFixable })
        #expect(issues.map(\.requiredValue) == [.unsigned(1)])
    }

    @Test func countsTheFilesACaptureSends() throws {
        var properties = try recordedProperties()
        #expect(CaptureSettings.expectedFileCount(in: properties) == 1)  // RAW+JPEG recorded, JPEG sent
        properties[.pcSaveImage] = try #require(properties[.pcSaveImage]).with(currentValue: .unsigned(1))
        #expect(CaptureSettings.expectedFileCount(in: properties) == 2)
    }

    @Test func aDialOwnedSettingIsNotFixable() throws {
        // The recorded aperture is display-only: the mode dial owns it.
        let aperture = try #require(try recordedProperties()[.fNumber])
        #expect(!aperture.accepts(.unsigned(800)))
    }

    @Test func requiresSingleShooting() throws {
        var properties = try recordedProperties()
        #expect(properties[.driveMode]?.currentValue == .unsigned(1))  // recorded in Single Shooting
        properties[.driveMode] = try #require(properties[.driveMode]).with(currentValue: .unsigned(0x10002))
        let issue = try #require(CaptureSettings.issues(in: properties).first { $0.code == .driveMode })
        #expect(issue.requiredValue == .unsigned(1))
        #expect(issue.isFixable)
    }

    @Test func acceptsOnlyListedValuesAndStepsOfARange() {
        let range = PropertyDescriptor(
            code: .colorTemperature, dataType: .uint16, isWritable: true, availability: .enabled,
            defaultValue: .unsigned(5500), currentValue: .unsigned(5500),
            constraint: .range(minimum: .unsigned(2500), maximum: .unsigned(9900), step: .unsigned(100)))
        #expect(range.accepts(.unsigned(2500)))
        #expect(range.accepts(.unsigned(5600)))
        #expect(!range.accepts(.unsigned(5650)))  // between steps
        #expect(!range.accepts(.unsigned(10_000)))
        let signed = PropertyDescriptor(
            code: SonyPropertyCode(rawValue: 0xD0FB), dataType: .int8, isWritable: true, availability: .enabled,
            defaultValue: .signed(0), currentValue: .signed(0),
            constraint: .range(minimum: .signed(-9), maximum: .signed(9), step: .signed(3)))
        #expect(signed.accepts(.signed(-6)))
        #expect(!signed.accepts(.signed(-5)))
        // Without a list or range nothing says what the camera takes.
        let unconstrained = PropertyDescriptor(
            code: SonyPropertyCode(rawValue: 0xD223), dataType: .string, isWritable: true, availability: .enabled,
            defaultValue: .string(""), currentValue: .string(""), constraint: .none)
        #expect(!unconstrained.accepts(.string("x")))
    }

    @Test func fixesSettingsInOrderWaitingForEach() async throws {
        let simulated = try SettingsCamera(fileFormat: 3, pcSaveImage: 2, driveMode: 0x10002)
        let camera = SonyCamera(name: "A6700", transport: simulated.transport)

        let skipped = try await camera.fixCaptureSettings()

        #expect(skipped.isEmpty)
        #expect(simulated.codesSet == [0xD253, 0xD269, 0x5013])
        #expect(CaptureSettings.issues(in: camera.properties).isEmpty)
    }

    @Test func reportsTheSettingsItCouldNotFix() async throws {
        let simulated = try SettingsCamera(fileFormat: 2, pcSaveImage: 2, driveMode: 0x10002)
        simulated.refusedProperty = 0x5013
        let camera = SonyCamera(name: "A6700", transport: simulated.transport)

        let skipped = try await camera.fixCaptureSettings()

        #expect(skipped.map(\.issue.code) == [.driveMode])
        #expect(skipped.map(\.skip) == [.notAccepted])
        #expect(simulated.codesSet == [0xD269])
    }

    private func recordedProperties() throws -> [SonyPropertyCode: PropertyDescriptor] {
        let descriptors = try PropertyDescriptor.parseAll(try Fixture.allProperties.data)
        return Dictionary(uniqueKeysWithValues: descriptors.map { ($0.code, $0) })
    }
}

@MainActor
struct CaptureTests {
    @Test func pressesTheShutterAndDownloadsEveryFile() async throws {
        let transport = FakeTransport()
        var waiting = ["DSC00001.ARW", "DSC00001.JPG"]
        var notReadyAnswers = 2
        transport.respond = { command, _ in
            switch command.operation {
            case .getObjectInfo:
                // Nothing at first: the image is still being written.
                if notReadyAnswers > 0 {
                    notReadyAnswers -= 1
                    return (PTPResponse(code: .ok), Data())
                }
                guard let name = waiting.first else { return (PTPResponse(code: .ok), Data()) }
                return (PTPResponse(code: .ok), objectInfo(filename: name))
            case .getObject:
                return (PTPResponse(code: .ok), Data(waiting.removeFirst().utf8))
            default:
                return (PTPResponse(code: .ok), Data())
            }
        }
        let camera = SonyCamera(name: "A6700", transport: transport)

        let files = try await camera.capture(expectedFiles: 2)

        #expect(files.map(\.info.filename) == ["DSC00001.ARW", "DSC00001.JPG"])
        let buttons = transport.sent(.controlDevice).map { ($0.command.parameters.first, $0.data) }
        #expect(buttons.map(\.0) == [0xD2C1, 0xD2C2, 0xD2C2, 0xD2C1])  // S1, S2 down; S2, S1 up
        #expect(buttons.map(\.1) == [Data([2, 0]), Data([2, 0]), Data([1, 0]), Data([1, 0])])
    }

    @Test func reportsTheFilesThatArrivedWhenTheRestDoNot() async throws {
        let transport = FakeTransport()
        var served = false
        transport.respond = { command, _ in
            switch command.operation {
            case .getObjectInfo where !served: (PTPResponse(code: .ok), objectInfo(filename: "DSC00002.ARW"))
            case .getObject:
                {
                    served = true
                    return (PTPResponse(code: .ok), Data([1]))
                }()
            default: (PTPResponse(code: .ok), Data())
            }
        }
        let camera = SonyCamera(name: "A6700", transport: transport)

        do {
            _ = try await camera.capture(expectedFiles: 2, timeout: .milliseconds(300))
            Issue.record("expected the capture to time out")
        } catch let error as CaptureError {
            #expect(error.files.map(\.info.filename) == ["DSC00002.ARW"])
            #expect(error.reason == .timedOut)
        }
    }

    @Test func releasesBothPressesWhenReleasingTheFullPressFails() async throws {
        // Pressing works; the first release of the full press is refused.
        let transport = FakeTransport()
        var refusals = 1
        transport.respond = { command, data in
            if command.parameters.first == 0xD2C2, data == Data([1, 0]), refusals > 0 {
                refusals -= 1
                return (PTPResponse(code: .deviceBusy), Data())
            }
            return (PTPResponse(code: .ok), Data())
        }
        let camera = SonyCamera(name: "A6700", transport: transport)

        await #expect(throws: PTPSessionError.rejected(.controlDevice, .deviceBusy)) {
            _ = try await camera.capture(expectedFiles: 2)
        }
        let releases = transport.sent(.controlDevice).filter { $0.data == Data([1, 0]) }
        #expect(releases.map { $0.command.parameters.first } == [0xD2C2, 0xD2C2, 0xD2C1])
    }

    @Test func releasesTheHalfPressWhenTheFullPressFails() async throws {
        let transport = FakeTransport()
        transport.respond = { command, _ in
            command.parameters.first == 0xD2C2
                ? (PTPResponse(code: .deviceBusy), Data()) : (PTPResponse(code: .ok), Data())
        }
        let camera = SonyCamera(name: "A6700", transport: transport)

        await #expect(throws: PTPSessionError.rejected(.controlDevice, .deviceBusy)) {
            _ = try await camera.capture(expectedFiles: 2)
        }
        let last = try #require(transport.sent(.controlDevice).last)
        #expect(last.command.parameters == [0xD2C1])
        #expect(last.data == Data([1, 0]))
    }

    @Test func refusesFilesFromDifferentCaptures() async throws {
        // A late JPEG of an earlier capture, then this capture's RAW.
        let transport = FakeTransport()
        var waiting = ["DSC00007.JPG", "DSC00008.ARW"]
        transport.respond = { command, _ in
            switch command.operation {
            case .getObjectInfo:
                waiting.first.map { (PTPResponse(code: .ok), objectInfo(filename: $0)) } ?? (
                    PTPResponse(code: .ok), Data()
                )
            case .getObject: (PTPResponse(code: .ok), Data(waiting.removeFirst().utf8))
            default: (PTPResponse(code: .ok), Data())
            }
        }
        let camera = SonyCamera(name: "A6700", transport: transport)

        do {
            _ = try await camera.capture(expectedFiles: 2)
            Issue.record("expected mixed captures to be refused")
        } catch let error as CaptureError {
            #expect(error.reason == .mixedCaptures)
            #expect(error.files.count == 2)
        }
    }

    @Test func drainsEveryWaitingImage() async throws {
        let transport = FakeTransport()
        var waiting = ["DSC00003.JPG", "DSC00004.JPG"]
        transport.respond = { command, _ in
            switch command.operation {
            case .getObjectInfo:
                waiting.first.map { (PTPResponse(code: .ok), objectInfo(filename: $0)) } ?? (
                    PTPResponse(code: .ok), Data()
                )
            case .getObject: (PTPResponse(code: .ok), Data(waiting.removeFirst().utf8))
            default: (PTPResponse(code: .ok), Data())
            }
        }
        let camera = SonyCamera(name: "A6700", transport: transport)

        var drained: [String] = []
        let count = try await camera.drainWaitingImages { drained.append($0.info.filename) }
        #expect(count == 2)
        #expect(drained == ["DSC00003.JPG", "DSC00004.JPG"])
    }
}

/// The recorded A6700 behind a fake transport that applies the file-format,
/// PC-save and drive-mode settings it's sent, so waiting for each sees it.
@MainActor
private final class SettingsCamera {
    let transport = FakeTransport()
    /// The properties set, in order.
    private(set) var codesSet: [UInt16] = []
    /// Answers setting this property with "busy".
    var refusedProperty: UInt16?
    private var fileFormat: UInt8
    private var pcSaveImage: UInt8
    private var driveMode: UInt32

    init(fileFormat: UInt8, pcSaveImage: UInt8, driveMode: UInt32) throws {
        self.fileFormat = fileFormat
        self.pcSaveImage = pcSaveImage
        self.driveMode = driveMode
        let recorded = try Fixture.allProperties.data
        transport.respond = { [unowned self] command, data in
            let code = command.parameters.first.map(UInt16.init)
            switch command.operation {
            case .setExtDevicePropValue where code == refusedProperty:
                return (PTPResponse(code: .deviceBusy), Data())
            case .setExtDevicePropValue:
                let payload = data ?? Data()
                codesSet.append(code ?? 0)
                switch code {
                case 0xD253: self.fileFormat = payload.withUnsafeBytes { $0.loadUnaligned(as: UInt8.self) }
                case 0xD269: self.pcSaveImage = payload.withUnsafeBytes { $0.loadUnaligned(as: UInt8.self) }
                case 0x5013: self.driveMode = payload.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                default: break
                }
            case .getAllExtDevicePropInfo:
                var dataset = try FakeTransport.dataset(recorded, setting: 0xD253, to: self.fileFormat)
                dataset = try FakeTransport.dataset(dataset, setting: 0xD269, to: self.pcSaveImage)
                dataset = try FakeTransport.dataset(dataset, setting: 0x5013, to: self.driveMode)
                return (PTPResponse(code: .ok), dataset)
            default:
                break
            }
            return (PTPResponse(code: .ok), Data())
        }
    }
}

extension PropertyDescriptor {
    /// A copy with another current value, for tests.
    func with(currentValue: PTPValue) -> PropertyDescriptor {
        PropertyDescriptor(
            code: code, dataType: dataType, isWritable: isWritable, availability: availability,
            defaultValue: defaultValue, currentValue: currentValue, constraint: constraint)
    }
}

@MainActor
struct AutofocusCaptureTests {
    @Test func waitsForFocusBeforeReleasing() async throws {
        var indications: [UInt8] = [1, 1, 2]  // unlocked, unlocked, focused
        let transport = try autofocusingCamera(mode: 0x0002) { indications.count > 1 ? indications.removeFirst() : 2 }
        let camera = SonyCamera(name: "A6700", transport: transport)
        try await camera.refreshProperties()

        await #expect(throws: CaptureError.self) {
            // No files are served; the point is the order of presses.
            try await camera.capture(expectedFiles: 1, timeout: .milliseconds(50), focusPollInterval: .milliseconds(1))
        }
        let controls = transport.sent(.controlDevice).map { ($0.command.parameters.first, $0.data) }
        #expect(controls.map(\.0) == [0xD2C1, 0xD2C2, 0xD2C2, 0xD2C1])
        #expect(indications.count == 1)  // polled until focused
    }

    @Test func singleShotAFThatCantFocusNeverReleases() async throws {
        let transport = try autofocusingCamera(mode: 0x0002) { 3 }  // no focus
        let camera = SonyCamera(name: "A6700", transport: transport)
        try await camera.refreshProperties()

        do {
            _ = try await camera.capture(expectedFiles: 2, focusPollInterval: .milliseconds(1))
            Issue.record("captured without focus")
        } catch let error as CaptureError {
            #expect(error.reason == .noFocus)
        }
        // Half press and its release only: the shutter never fired.
        #expect(transport.sent(.controlDevice).map { $0.command.parameters.first } == [0xD2C1, 0xD2C1])
    }

    @Test func dmfThatCantFocusGivesUpAtOnce() async throws {
        let transport = try autofocusingCamera(mode: 0x8006) { 3 }  // DMF, no focus
        let camera = SonyCamera(name: "A6700", transport: transport)
        try await camera.refreshProperties()

        let start = ContinuousClock.now
        do {
            _ = try await camera.capture(
                expectedFiles: 2, focusTimeout: .seconds(10), focusPollInterval: .milliseconds(1))
            Issue.record("captured without focus")
        } catch let error as CaptureError {
            #expect(error.reason == .noFocus)
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func continuousAFGivesUpAfterTheTimeout() async throws {
        let transport = try autofocusingCamera(mode: 0x8004) { 7 }  // tracking, no focus
        let camera = SonyCamera(name: "A6700", transport: transport)
        try await camera.refreshProperties()

        do {
            _ = try await camera.capture(
                expectedFiles: 2, focusTimeout: .milliseconds(30), focusPollInterval: .milliseconds(1))
            Issue.record("captured without focus")
        } catch let error as CaptureError {
            #expect(error.reason == .noFocus)
        }
        #expect(transport.sent(.controlDevice).map { $0.command.parameters.first } == [0xD2C1, 0xD2C1])
    }

    /// A camera in focus mode `mode` whose focus indication is `indication()`
    /// at each property read.
    private func autofocusingCamera(mode: UInt16, indication: @escaping () -> UInt8) throws -> FakeTransport {
        let recorded = try Fixture.allProperties.data
        let transport = FakeTransport()
        transport.respond = { command, _ in
            switch command.operation {
            case .getAllExtDevicePropInfo:
                var dataset = try FakeTransport.dataset(recorded, setting: 0x500A, to: mode)
                dataset = try FakeTransport.dataset(dataset, setting: 0xD213, to: indication())
                return (PTPResponse(code: .ok), dataset)
            default:
                return (PTPResponse(code: .ok), Data())
            }
        }
        return transport
    }
}
