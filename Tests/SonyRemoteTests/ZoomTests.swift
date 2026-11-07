import CameraFixtures
import Foundation
import Testing

@testable import SonyProtocol
@testable import SonyRemote

@MainActor
struct ZoomTests {
    @Test func zoomsToATargetAndSlowsDownNearIt() async throws {
        let lens = try SimulatedPowerZoom(startingAt: 37_000)
        let camera = SonyCamera(name: "A6700", transport: lens.transport)
        try await camera.refreshProperties()

        let reached = try await camera.zoom(to: 50_000, pollInterval: .milliseconds(1))

        #expect(reached == 50_000)
        #expect(lens.speeds.first == 4)  // fast while far away
        #expect(lens.speeds.contains(1))  // slow for the last millimetres
        #expect(lens.speeds.last == 0)  // and stopped
    }

    @Test func zoomsTowardsWideWithNegativeSpeeds() async throws {
        let lens = try SimulatedPowerZoom(startingAt: 60_000)
        let camera = SonyCamera(name: "A6700", transport: lens.transport)
        try await camera.refreshProperties()

        let reached = try await camera.zoom(to: 45_000, pollInterval: .milliseconds(1))

        #expect(reached == 45_000)
        #expect(lens.speeds.dropLast().allSatisfy { $0 < 0 })
    }

    @Test func stopsTheLensWhenItStalls() async throws {
        let lens = try SimulatedPowerZoom(startingAt: 104_000, longEnd: 105_000)
        let camera = SonyCamera(name: "A6700", transport: lens.transport)
        try await camera.refreshProperties()

        await #expect(throws: SonyCamera.ZoomError.stalled(atThousandthsOfMillimetre: 105_000)) {
            try await camera.zoom(to: 120_000, pollInterval: .milliseconds(5), stallTimeout: .milliseconds(50))
        }
        #expect(lens.speeds.last == 0)
    }

    @Test func doesNotZoomWhileTheCameraDoesNotAllowIt() async throws {
        let transport = FakeTransport()
        let dataset = try FakeTransport.dataset(Fixture.allProperties.data, setting: 0xD25B, to: UInt8(0))
        transport.respond = { command, _ in
            command.operation == .getAllExtDevicePropInfo
                ? (PTPResponse(code: .ok), dataset) : (PTPResponse(code: .ok), Data())
        }
        let camera = SonyCamera(name: "A6700", transport: transport)
        try await camera.refreshProperties()

        #expect(!camera.isZoomAvailable)
        await #expect(throws: SonyCamera.ZoomError.unavailable) { try await camera.startZoom(speed: 1) }
        #expect(transport.sent(.controlDevice).isEmpty)
        try await camera.stopZoom()  // stopping is always allowed
        #expect(transport.sent(.controlDevice).count == 1)
    }

    @Test func zoomsOnlyAtTheSpeedsTheCameraReports() async throws {
        let transport = FakeTransport()
        let dataset = try Fixture.allProperties.data
        transport.respond = { command, _ in
            command.operation == .getAllExtDevicePropInfo
                ? (PTPResponse(code: .ok), dataset) : (PTPResponse(code: .ok), Data())
        }
        let camera = SonyCamera(name: "A6700", transport: transport)
        #expect(camera.zoomSpeeds == SonyCamera.defaultZoomSpeeds)  // before the camera says
        try await camera.refreshProperties()

        #expect(camera.zoomSpeeds == -8...8)  // as the A6700 reports 0xD25E
        try await camera.startZoom(speed: -8)
        await #expect(throws: SonyCamera.ZoomError.unsupportedSpeed(9)) { try await camera.startZoom(speed: 9) }
        await #expect(throws: SonyCamera.ZoomError.unsupportedSpeed(.min)) {
            try await camera.startZoom(speed: .min)
        }
        #expect(transport.sent(.controlDevice).count == 1)
    }

    @Test func savesAndLoadsPresetsAsControls() async throws {
        let transport = FakeTransport()
        let camera = SonyCamera(name: "A6700", transport: transport)
        try await camera.saveZoomAndFocusPreset(2)
        try await camera.loadZoomAndFocusPreset(2)
        let sent = transport.sent(.controlDevice)
        #expect(sent.map(\.command.parameters) == [[0xD2E9], [0xD2EA]])
        #expect(sent.map(\.data) == [Data([2]), Data([2])])
    }
}

/// A power zoom behind a fake transport: zoom commands set its speed, and
/// each property read moves the focal length by 1 mm per unit of speed
/// (whole millimetres, as the real lens reports), stopping at its ends.
@MainActor
private final class SimulatedPowerZoom {
    let transport = FakeTransport()
    private(set) var speeds: [Int8] = []
    private var focalLength: UInt32
    private var speed: Int8 = 0

    init(startingAt start: UInt32, longEnd: UInt32 = 105_000) throws {
        focalLength = start
        let dataset = try Fixture.allProperties.data
        transport.respond = { [unowned self] command, data in
            switch command.operation {
            case .controlDevice where command.parameters == [UInt32(SonyControlCode.zoomOperation.rawValue)]:
                speed = Int8(bitPattern: data?.first ?? 0)
                speeds.append(speed)
            case .getAllExtDevicePropInfo:
                let next = Int64(focalLength) + Int64(speed) * 1000
                focalLength = UInt32(min(max(next, 18_000), Int64(longEnd)))
                return (PTPResponse(code: .ok), try Self.dataset(dataset, withFocalLength: focalLength))
            default:
                break
            }
            return (PTPResponse(code: .ok), Data())
        }
    }

    /// The recorded dataset with the focal length's current value replaced.
    /// The entry is code 0xD00B, UINT32, read-only, enabled, then default
    /// and current value.
    private static func dataset(_ dataset: Data, withFocalLength value: UInt32) throws -> Data {
        let entry: [UInt8] = [0x0B, 0xD0, 0x06, 0x00, 0x00, 0x01]
        guard let range = dataset.firstRange(of: entry) else { throw CocoaError(.coderInvalidValue) }
        var patched = dataset
        let current = range.upperBound + 4
        withUnsafeBytes(of: value.littleEndian) { patched.replaceSubrange(current..<current + 4, with: $0) }
        return patched
    }
}
