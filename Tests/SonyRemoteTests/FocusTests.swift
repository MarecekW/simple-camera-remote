import CameraFixtures
import Foundation
import Testing

@testable import SonyProtocol
@testable import SonyRemote

@MainActor
struct FocusTests {
    @Test(arguments: [
        (0.5, 0.0, 320), (0.0, 82.0 / 640, 41), (1.0, 82.0 / 640, 598), (0.25, 0.0, 160), (1.0, 0.0, 639),
        (0.9, 50.0, 320),  // a nonsense frame size stays inside the grid
    ])
    func mapsAPointOntoTheCameraGrid(fraction: Double, frame: Double, expected: Int) {
        #expect(SonyCamera.gridCoordinate(fraction, size: 640, frame: frame) == expected)
    }

    @Test(arguments: [
        (1e300, 639), (-1e300, 0), (2.0, 639), (-0.5, 0), (Double.infinity, 320), (Double.nan, 320),
    ])
    func keepsAnyFractionOnTheGrid(fraction: Double, expected: Int) {
        // A preset file can hold any number; none may trap or leave the grid.
        #expect(SonyCamera.gridCoordinate(fraction, size: 640, frame: 0) == expected)
        #expect(SonyCamera.gridCoordinate(0.5, size: 640, frame: fraction) >= 0)
    }

    @Test func sendsOnlyTheKnownFocusSteps() async throws {
        let transport = FakeTransport()
        let camera = SonyCamera(name: "A6700", transport: transport)
        try await camera.stepFocus(-7)
        try await camera.stepFocus(3)
        for step: Int16 in [0, 2, -8, 100, .min] {
            await #expect(throws: SonyCameraError.unsupportedFocusStep(step)) { try await camera.stepFocus(step) }
        }
        #expect(transport.sent(.controlDevice).count == 2)
    }

    @Test func movesTheAFPointInASpotArea() async throws {
        let simulated = try SimulatedCamera()  // recorded in Spot L
        let camera = SonyCamera(name: "A6700", transport: simulated.transport)
        try await camera.refreshProperties()

        try await camera.moveAFPoint(to: .init(x: 0.25, y: 0.5))

        #expect(simulated.transport.sent(.setExtDevicePropValue).isEmpty)
        let move = try #require(simulated.transport.sent(.controlDevice).last)
        #expect(move.command.parameters == [0xD2DC])
        #expect(move.data == withUnsafeBytes(of: (UInt32(160) << 16 | 240).littleEndian) { Data($0) })
    }

    @Test func switchesWideToSpotBeforeMovingThePoint() async throws {
        let simulated = try SimulatedCamera(focusArea: 0x001)  // Wide
        let camera = SonyCamera(name: "A6700", transport: simulated.transport)
        try await camera.refreshProperties()

        try await camera.moveAFPoint(to: .init(x: 0.5, y: 0.5))

        #expect(simulated.focusArea == 0x102)
        #expect(simulated.transport.sent(.controlDevice).map(\.command.parameters) == [[0xD2DC]])
    }

    @Test func doesNotAutofocusOrChangeTheModeInMF() async throws {
        let simulated = try SimulatedCamera(focusMode: 0x0001, focusIndication: 2)
        let camera = SonyCamera(name: "A6700", transport: simulated.transport)
        try await camera.refreshProperties()

        await #expect(throws: SonyCameraError.manualFocus) {
            try await camera.focusOnce(pollInterval: .milliseconds(1))
        }
        #expect(simulated.focusModesSet.isEmpty)
        #expect(simulated.transport.sent(.controlDevice).isEmpty)
    }

    @Test func reportsNoFocusAndStillLetsGo() async throws {
        let simulated = try SimulatedCamera(focusMode: 0x0002, focusIndication: 3)
        let camera = SonyCamera(name: "A6700", transport: simulated.transport)
        try await camera.refreshProperties()

        #expect(try await camera.focusOnce(pollInterval: .milliseconds(1)) == .noFocus)
        #expect(simulated.transport.sent(.controlDevice).last?.data == Data([1, 0]))
        #expect(simulated.focusModesSet.isEmpty)
    }

    @Test func letsGoWhenThePressFails() async throws {
        let simulated = try SimulatedCamera(focusMode: 0x0002, focusIndication: 2)
        simulated.refusesHalfPress = true
        let camera = SonyCamera(name: "A6700", transport: simulated.transport)
        try await camera.refreshProperties()

        await #expect(throws: PTPSessionError.self) { try await camera.focusOnce(pollInterval: .milliseconds(1)) }
        #expect(simulated.transport.sent(.controlDevice).last?.data == Data([1, 0]))
    }

    @Test(arguments: [(UInt16(0x002), UInt16(0x002)), (0x201, 0x205), (0x003, 0x102)])
    func switchesOnlyAreasWithoutAMovableFrame(area: UInt16, expected: UInt16) async throws {
        let simulated = try SimulatedCamera(focusArea: area)
        let camera = SonyCamera(name: "A6700", transport: simulated.transport)
        try await camera.refreshProperties()

        let switched = try await camera.moveAFPoint(to: .centre)
        #expect(simulated.focusArea == expected)
        #expect(switched == (area == expected ? nil : UInt64(expected)))
    }

    @Test func sendsNothingWhenTheCameraDoesNotOfferSpot() async throws {
        let simulated = try SimulatedCamera(focusArea: 0x001, focusAreaAvailability: 2)  // Wide, display only
        let camera = SonyCamera(name: "A6700", transport: simulated.transport)
        try await camera.refreshProperties()

        await #expect(throws: SonyCameraError.valueNotOffered(.focusArea, .unsigned(0x102))) {
            try await camera.moveAFPoint(to: .centre)
        }
        #expect(simulated.transport.sent(.setExtDevicePropValue).isEmpty)
        #expect(simulated.transport.sent(.controlDevice).isEmpty)
    }

    @Test func neverSendsARatioTheCameraDoesNotList() async throws {
        let simulated = try SimulatedCamera()
        let camera = SonyCamera(name: "A6700", transport: simulated.transport)
        try await camera.refreshProperties()

        await #expect(throws: SonyCameraError.valueNotOffered(.focusMagnifier, .unsigned(0x50_FFFF_FFFF))) {
            try await camera.magnify(8, at: .centre)
        }
        #expect(simulated.transport.sent(.setExtDevicePropValue).isEmpty)
    }

    @Test func entersTheMagnifierThenPlacesIt() async throws {
        let simulated = try SimulatedCamera()
        let camera = SonyCamera(name: "A6700", transport: simulated.transport)
        try await camera.refreshProperties()
        #expect(camera.magnifierRatios == [6.1, 12.1])
        #expect(camera.magnification == nil)

        try await camera.magnify(6.1, at: .init(x: 0.5, y: 0.5))

        #expect(simulated.magnifierValuesSet == [0x3D_FFFF_FFFF, 0x3D_0140_00F0])
        #expect(camera.magnification == 6.1)
        try await camera.refreshProperties()
        #expect(camera.magnifierCentre == .init(x: 0.5, y: 0.5))
        // The right edge of the magnified view is half a magnified width
        // right of the centre.
        let edge = camera.unmagnified(.init(x: 1, y: 0.5))
        #expect(abs(edge.x - (0.5 + 0.5 / 6.1)) < 1e-9)
        try await camera.endMagnification()
        #expect(simulated.magnifierValuesSet.last == 0xFFFF_FFFF)
    }

    @Test func movesTheMagnifierWithOneValueOnceMagnified() async throws {
        let simulated = try SimulatedCamera(magnifier: 0x3D_0140_00F0)
        let camera = SonyCamera(name: "A6700", transport: simulated.transport)
        try await camera.refreshProperties()

        try await camera.magnify(6.1, at: .init(x: 0.25, y: 0.5))
        #expect(simulated.magnifierValuesSet == [0x3D_00A0_00F0])
    }

    @Test func entersTheMagnifierOnceWithoutAPoint() async throws {
        let simulated = try SimulatedCamera()
        let camera = SonyCamera(name: "A6700", transport: simulated.transport)
        try await camera.refreshProperties()

        try await camera.magnify(12.1)
        #expect(simulated.magnifierValuesSet == [0x79_FFFF_FFFF])
    }

    @Test func appliesSettingsInOrderAndReportsWhatItSkips() async throws {
        let simulated = try SimulatedCamera(focusArea: 0x001, focusMode: 0x8004)
        let camera = SonyCamera(name: "A6700", transport: simulated.transport)

        let skipped = try await camera.apply([
            (.focusMode, .unsigned(0x0002)),
            (.focusArea, .unsigned(0x0999)),  // not in the camera's list
            (.focusArea, .unsigned(0x0102)),
            (SonyPropertyCode(rawValue: 0xFFFE), .unsigned(1)),
            (.focusMode, .unsigned(0x0002)),  // already right: not sent again
        ])

        #expect(simulated.focusModesSet == [0x0002])
        #expect(simulated.focusArea == 0x102)
        #expect(skipped.map(\.code) == [.focusArea, SonyPropertyCode(rawValue: 0xFFFE)])
        #expect(skipped.map(\.skip) == [.notAccepted, .notOffered])
    }

    @Test func goesOnPastASettingTheCameraRefuses() async throws {
        let simulated = try SimulatedCamera(focusArea: 0x001, focusMode: 0x8004)
        simulated.refusedProperty = 0x500A
        let camera = SonyCamera(name: "A6700", transport: simulated.transport)

        let skipped = try await camera.apply([(.focusMode, .unsigned(0x0002)), (.focusArea, .unsigned(0x0102))])

        #expect(skipped.map(\.code) == [.focusMode])
        #expect(skipped.map(\.skip) == [.notAccepted])
        #expect(simulated.focusArea == 0x102)
    }
}

/// The recorded A6700 behind a fake transport that applies the focus
/// settings it's sent, so waiting for a change sees it.
@MainActor
private final class SimulatedCamera {
    let transport = FakeTransport()
    private(set) var focusArea: UInt16
    private(set) var focusModesSet: [UInt16] = []
    private(set) var magnifierValuesSet: [UInt64] = []
    /// Answers the shutter's half press with "busy".
    var refusesHalfPress = false
    /// Answers setting this property with "busy".
    var refusedProperty: UInt16?
    private var focusMode: UInt16
    private var magnifier: UInt64

    init(
        focusArea: UInt16 = 0x103, focusAreaAvailability: UInt8 = 1, focusMode: UInt16 = 0x8004,
        focusIndication: UInt8 = 1, magnifier: UInt64 = 0x0140_00F0  // off, at the centre
    ) throws {
        self.focusArea = focusArea
        self.focusMode = focusMode
        self.magnifier = magnifier
        let recorded = try FakeTransport.dataset(
            Fixture.allProperties.data, making: 0xD22C, available: focusAreaAvailability)
        transport.respond = { [unowned self] command, data in
            switch command.operation {
            case .controlDevice where refusesHalfPress && command.parameters.first == 0xD2C1 && data == Data([2, 0]):
                return (PTPResponse(code: .deviceBusy), Data())
            case .setExtDevicePropValue where command.parameters.first.map(UInt16.init) == refusedProperty:
                return (PTPResponse(code: .deviceBusy), Data())
            case .setExtDevicePropValue:
                let payload = data ?? Data()
                switch command.parameters.first {
                case 0xD22C: self.focusArea = payload.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
                case 0x500A:
                    self.focusMode = payload.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
                    focusModesSet.append(self.focusMode)
                case 0xD254:
                    self.magnifier = payload.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                    magnifierValuesSet.append(self.magnifier)
                default: break
                }
            case .getAllExtDevicePropInfo:
                var dataset = try FakeTransport.dataset(recorded, setting: 0xD22C, to: self.focusArea)
                dataset = try FakeTransport.dataset(dataset, setting: 0x500A, to: self.focusMode)
                dataset = try FakeTransport.dataset(dataset, setting: 0xD213, to: focusIndication)
                dataset = try FakeTransport.dataset(dataset, setting: 0xD254, to: self.magnifier)
                return (PTPResponse(code: .ok), dataset)
            default:
                break
            }
            return (PTPResponse(code: .ok), Data())
        }
    }
}
