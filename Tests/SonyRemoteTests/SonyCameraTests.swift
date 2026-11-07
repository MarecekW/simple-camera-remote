import Foundation
import SonyProtocol
import Testing

@testable import SonyRemote

@MainActor
struct SonyCameraTests {
    // MARK: - Connecting

    @Test func runsTheHandshakeInOrder() async throws {
        let transport = try FakeTransport.a6700()
        let camera = SonyCamera(name: "A6700", transport: transport)
        try await camera.connect()
        defer { camera.disconnect() }

        let handshake = transport.sent.prefix(5).map(\.command)
        #expect(
            handshake == [
                PTPCommand(.sdioConnect, 1, 0, 0),
                PTPCommand(.sdioConnect, 2, 0, 0),
                PTPCommand(.sdioGetExtDeviceInfo, 300),
                PTPCommand(.sdioConnect, 3, 0, 0),
                PTPCommand(.getAllExtDevicePropInfo),
            ])
        #expect(camera.isConnected)
        #expect(camera.deviceInfo?.protocolVersion == 300)
        #expect(camera.properties.count == 351)
    }

    @Test func takesPriorityOverTheCameraDialsWhenConnecting() async throws {
        // The recorded camera reports priority key 0 (camera dials).
        let transport = try FakeTransport.a6700()
        let camera = SonyCamera(name: "A6700", transport: transport)
        try await camera.connect()
        defer { camera.disconnect() }

        let writes = transport.sent(.setExtDevicePropValue)
        #expect(writes.map(\.command.parameters) == [[UInt32(SonyPropertyCode.priorityKey.rawValue)]])
        #expect(writes.first?.data == Data([1]))  // UINT8 1 = PC
    }

    @Test func leavesThePriorityKeyAloneWhenThePCAlreadyHasIt() async throws {
        let transport = try FakeTransport.a6700(priorityKey: 1)
        let camera = SonyCamera(name: "A6700", transport: transport)
        try await camera.connect()
        defer { camera.disconnect() }

        #expect(transport.sent(.setExtDevicePropValue).isEmpty)
    }

    @Test func leavesTheDialsInChargeWhenPreferred() async throws {
        let transport = try FakeTransport.a6700()  // camera dials
        let camera = SonyCamera(name: "A6700", transport: transport)
        camera.prefersPCPriority = false
        try await camera.connect()
        defer { camera.disconnect() }

        #expect(transport.sent(.setExtDevicePropValue).isEmpty)
    }

    @Test func handsTheDialsBackWithoutChangingThePreference() async throws {
        let transport = try FakeTransport.a6700(priorityKey: 1)
        let camera = SonyCamera(name: "A6700", transport: transport)
        try await camera.connect()
        defer { camera.disconnect() }

        try await camera.setPCPriority(false, remember: false)
        #expect(transport.sent(.setExtDevicePropValue).last?.data == Data([0]))
        #expect(camera.prefersPCPriority)
    }

    @Test func reconnectsAfterADisconnect() async throws {
        let transport = try FakeTransport.a6700()
        let camera = SonyCamera(name: "A6700", transport: transport)
        try await camera.connect()
        camera.disconnect()
        try await camera.connect()
        defer { camera.disconnect() }

        // The second session's monitoring works: an event still triggers a read.
        let readsBefore = transport.sent(.getAllExtDevicePropInfo).count
        transport.emit(PTPEvent(code: .propertiesChanged))
        try await waitUntil { transport.sent(.getAllExtDevicePropInfo).count > readsBefore }
        #expect(camera.isConnected)
    }

    @Test func aDisconnectDuringConnectWins() async throws {
        let transport = try FakeTransport.a6700()
        transport.holdsPropertyReads = true
        let camera = SonyCamera(name: "A6700", transport: transport)
        let connecting = Task { try await camera.connect() }
        try await waitUntil { transport.heldReadCount == 1 }

        camera.disconnect()
        transport.releaseHeldReads()

        await #expect(throws: CancellationError.self) { try await connecting.value }
        #expect(!camera.isConnected)
    }

    @Test func explainsAStaleSession() async throws {
        let transport = try FakeTransport.a6700()
        transport.respond = { _, _ in (PTPResponse(code: PTPResponseCode(rawValue: 0xA101)), Data()) }
        let camera = SonyCamera(name: "A6700", transport: transport)

        await #expect(throws: SonyCameraError.staleSession) { try await camera.connect() }
        #expect(!transport.isOpen)
        #expect(!camera.isConnected)
    }

    @Test func refusesAnOlderProtocolAndClosesTheSession() async throws {
        let transport = FakeTransport()
        var oldInfo = ByteWriterForTests()
        oldInfo.write(UInt16(200))
        oldInfo.write(UInt32(0))
        oldInfo.write(UInt32(0))
        let data = oldInfo.data
        transport.respond = { command, _ in
            (PTPResponse(code: .ok), command.operation == .sdioGetExtDeviceInfo ? data : Data())
        }
        let camera = SonyCamera(name: "old", transport: transport)

        await #expect(throws: SonyCameraError.unsupportedProtocol(200)) { try await camera.connect() }
        #expect(transport.closeCount == 1)
    }

    // MARK: - Properties

    @Test func writesValuesInTheWidthTheCameraReports() async throws {
        let transport = try FakeTransport.a6700()
        let camera = SonyCamera(name: "A6700", transport: transport)
        try await camera.connect()
        defer { camera.disconnect() }

        try await camera.setProperty(.fNumber, to: .unsigned(800))  // f/8, UINT16
        try await camera.setProperty(.exposureCompensation, to: .signed(-1000))  // −1 EV, INT16

        let writes = transport.sent(.setExtDevicePropValue).suffix(2)
        #expect(writes.map(\.data) == [Data([0x20, 0x03]), Data([0x18, 0xFC])])
    }

    @Test func rereadsPropertiesWhenTheCameraReportsAChange() async throws {
        let transport = try FakeTransport.a6700()
        let camera = SonyCamera(name: "A6700", transport: transport)
        try await camera.connect()
        defer { camera.disconnect() }
        let readsBefore = transport.sent(.getAllExtDevicePropInfo).count

        transport.emit(PTPEvent(code: .propertiesChanged, parameters: [0]))
        try await waitUntil { transport.sent(.getAllExtDevicePropInfo).count > readsBefore }
    }

    @Test func foldsConcurrentRefreshesIntoOneMoreRead() async throws {
        let transport = try FakeTransport.a6700(priorityKey: 1)
        let camera = SonyCamera(name: "A6700", transport: transport, pollingInterval: .seconds(3600))
        try await camera.connect()
        defer { camera.disconnect() }
        let readsBefore = transport.sent(.getAllExtDevicePropInfo).count

        transport.holdsPropertyReads = true
        let first = Task { try await camera.refreshProperties() }
        try await waitUntil { transport.heldReadCount == 1 }
        let second = Task { try await camera.refreshProperties() }
        let third = Task { try await camera.refreshProperties() }
        try await Task.sleep(for: .milliseconds(20))  // let both join the queue
        transport.releaseHeldReads()

        try await first.value
        try await second.value
        try await third.value
        // The running read, plus one shared by the two that arrived during it.
        #expect(transport.sent(.getAllExtDevicePropInfo).count == readsBefore + 2)
    }

    @Test func endsTheSessionWhenARefreshFails() async throws {
        let transport = try FakeTransport.a6700(priorityKey: 1)
        let camera = SonyCamera(name: "A6700", transport: transport)
        try await camera.connect()

        transport.respond = { _, _ in throw PTPSessionError.timedOut(.getAllExtDevicePropInfo) }
        transport.emit(PTPEvent(code: .propertiesChanged))

        try await waitUntil { !camera.isConnected }
        #expect(camera.sessionEndReason as? PTPSessionError == .timedOut(.getAllExtDevicePropInfo))
        #expect(!transport.isOpen)
    }

    @Test func stopsReadingAfterADisconnect() async throws {
        let transport = try FakeTransport.a6700(priorityKey: 1)
        let camera = SonyCamera(name: "A6700", transport: transport, pollingInterval: .milliseconds(20))
        try await camera.connect()
        camera.disconnect()
        let readsAfterDisconnect = transport.sent(.getAllExtDevicePropInfo).count

        try await Task.sleep(for: .milliseconds(150))
        transport.emit(PTPEvent(code: .propertiesChanged))
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.sent(.getAllExtDevicePropInfo).count == readsAfterDisconnect)
    }

    @Test func noticesWhenTheCameraGoesAway() async throws {
        let transport = try FakeTransport.a6700()
        let camera = SonyCamera(name: "A6700", transport: transport)
        try await camera.connect()

        transport.endEvents()
        try await waitUntil { !camera.isConnected }
        #expect(!transport.isOpen)
        #expect(camera.sessionEndReason as? PTPSessionError == .deviceRemoved)
    }

    // MARK: - Captured images

    @Test func reportsNothingWaitingForAnEmptyObjectInfo() async throws {
        let transport = FakeTransport()
        let camera = SonyCamera(name: "A6700", transport: transport)
        #expect(try await camera.downloadCapturedImage() == nil)
        #expect(transport.sent(.getObject).isEmpty)
    }

    @Test func downloadsAWaitingImage() async throws {
        let transport = FakeTransport()
        let image = Data(repeating: 0xAB, count: 64)
        transport.respond = { command, _ in
            switch command.operation {
            case .getObjectInfo: (PTPResponse(code: .ok), objectInfo(filename: "DSC00001.ARW"))
            case .getObject: (PTPResponse(code: .ok), image)
            default: (PTPResponse(code: .generalError), Data())
            }
        }
        let camera = SonyCamera(name: "A6700", transport: transport)

        let file = try #require(try await camera.downloadCapturedImage())
        #expect(file.info.filename == "DSC00001.ARW")
        #expect(file.data == image)
    }

    // MARK: - Helpers

    /// Polls `condition` on the main actor, failing after a second.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition not met within 1 s")
    }
}

/// A minimal ObjectInfo dataset with only a filename filled in.
func objectInfo(filename: String) -> Data {
    var writer = ByteWriterForTests()
    writer.write(UInt32(0))  // storage ID
    writer.write(UInt16(0xB101))  // format
    writer.write(UInt16(0))  // protection
    writer.write(UInt32(0))  // size
    writer.write(UInt16(0))  // thumbnail format
    for _ in 0..<5 { writer.write(UInt32(0)) }  // thumbnail size/width/height, width, height
    for _ in 0..<2 { writer.write(UInt32(0)) }  // bit depth, parent
    writer.write(UInt16(0))  // association type
    for _ in 0..<2 { writer.write(UInt32(0)) }  // association description, sequence
    let name = Array(filename.utf16) + [0]
    writer.write(UInt8(name.count))
    for unit in name { writer.write(unit) }
    return writer.data
}

/// Little-endian writer for building datasets (SonyProtocol's own is internal).
struct ByteWriterForTests {
    private(set) var data = Data()

    mutating func write<Integer: FixedWidthInteger>(_ value: Integer) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
