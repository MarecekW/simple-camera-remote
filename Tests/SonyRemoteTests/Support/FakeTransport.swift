import CameraFixtures
import Foundation
import SonyProtocol
import SonyRemote

/// A `PTPTransport` that answers from a script instead of a camera, and
/// records what was sent.
@MainActor
final class FakeTransport: PTPTransport {
    struct SentCommand: Equatable {
        let command: PTPCommand
        let data: Data?
    }

    /// Answers a command; the default answers OK with no data.
    var respond: (PTPCommand, Data?) throws -> (PTPResponse, Data) = { _, _ in (PTPResponse(code: .ok), Data()) }
    /// While true, property reads wait until `releaseHeldReads()`.
    var holdsPropertyReads = false
    private(set) var sent: [SentCommand] = []
    private(set) var isOpen = false
    private(set) var closeCount = 0
    private var subscribers: [AsyncStream<PTPEvent>.Continuation] = []
    private var heldReads: [CheckedContinuation<Void, Never>] = []

    func subscribeToEvents() -> AsyncStream<PTPEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: PTPEvent.self)
        subscribers.append(continuation)
        return stream
    }

    func open() async throws { isOpen = true }

    func close() {
        isOpen = false
        closeCount += 1
    }

    func exchange(_ command: PTPCommand, data: Data?, timeout: Duration) async throws -> (PTPResponse, Data) {
        sent.append(SentCommand(command: command, data: data))
        if holdsPropertyReads, command.operation == .getAllExtDevicePropInfo {
            await withCheckedContinuation { heldReads.append($0) }
        }
        return try respond(command, data)
    }

    var heldReadCount: Int { heldReads.count }

    func releaseHeldReads() {
        holdsPropertyReads = false
        let held = heldReads
        heldReads = []
        for read in held { read.resume() }
    }

    func emit(_ event: PTPEvent) {
        for subscriber in subscribers { subscriber.yield(event) }
    }

    /// The camera goes away: every event stream ends.
    func endEvents() {
        for subscriber in subscribers { subscriber.finish() }
        subscribers = []
    }

    func sent(_ operation: PTPOperationCode) -> [SentCommand] {
        sent.filter { $0.command.operation == operation }
    }
}

extension FakeTransport {
    /// A transport that completes the handshake with the A6700's recorded
    /// answers, then answers everything else OK.
    static func a6700(priorityKey: UInt8 = 0) throws -> FakeTransport {
        let deviceInfo = try Fixture.extendedDeviceInfo.data
        let properties = try dataset(Fixture.allProperties.data, setting: 0xD25A, to: priorityKey)
        let transport = FakeTransport()
        transport.respond = { command, _ in
            switch command.operation {
            case .sdioGetExtDeviceInfo: (PTPResponse(code: .ok), deviceInfo)
            case .getAllExtDevicePropInfo: (PTPResponse(code: .ok), properties)
            default: (PTPResponse(code: .ok), Data())
            }
        }
        return transport
    }

    /// `dataset` with the current value of property `code` replaced; the
    /// value's width picks the PTP type (UINT8 to UINT64).  An entry is code,
    /// type, get/set, enabled, then the default and current values.
    static func dataset<Value: FixedWidthInteger & UnsignedInteger>(
        _ dataset: Data, setting code: UInt16, to value: Value
    ) throws -> Data {
        let size = MemoryLayout<Value>.size
        // UINT8, UINT16, UINT32, UINT64.
        guard let type = [1: UInt8(0x02), 2: 0x04, 4: 0x06, 8: 0x08][size] else {
            throw CocoaError(.coderInvalidValue)
        }
        let entry = withUnsafeBytes(of: code.littleEndian) { Array($0) } + [type, 0x00]
        guard let range = dataset.firstRange(of: entry) else { throw CocoaError(.coderInvalidValue) }
        let current = range.upperBound + 2 + size
        var patched = dataset
        withUnsafeBytes(of: value.littleEndian) { patched.replaceSubrange(current..<current + size, with: $0) }
        // The byte pattern could also occur inside another entry: check the
        // property itself now reads the value.
        let descriptor = try PropertyDescriptor.parseAll(patched).first { $0.code.rawValue == code }
        guard descriptor?.currentValue == .unsigned(UInt64(value)) else { throw CocoaError(.coderInvalidValue) }
        return patched
    }

    /// `dataset` with property `code`'s availability replaced (0 disabled,
    /// 1 enabled, 2 display only).  An entry is code, type, get/set, then
    /// the availability.
    static func dataset(_ dataset: Data, making code: UInt16, available availability: UInt8) throws -> Data {
        let descriptors = try PropertyDescriptor.parseAll(dataset)
        guard let type = descriptors.first(where: { $0.code.rawValue == code })?.dataType else {
            throw CocoaError(.coderInvalidValue)
        }
        let entry =
            withUnsafeBytes(of: code.littleEndian) { Array($0) }
            + withUnsafeBytes(of: type.rawValue.littleEndian) { Array($0) }
        guard let range = dataset.firstRange(of: entry) else { throw CocoaError(.coderInvalidValue) }
        var patched = dataset
        patched[range.upperBound + 1] = availability
        let descriptor = try PropertyDescriptor.parseAll(patched).first { $0.code.rawValue == code }
        guard descriptor?.availability.rawValue == availability else { throw CocoaError(.coderInvalidValue) }
        return patched
    }
}
