import Foundation

/// The type field of a USB PTP container (PIMA 15740 / USB Still Image class).
enum PTPContainerType: UInt16 {
    case command = 1
    case data = 2
    case response = 3
    case event = 4
}

/// An operation request: the command container sent to the camera.
public struct PTPCommand: Equatable, Sendable {
    public let operation: PTPOperationCode
    public let parameters: [UInt32]

    public init(_ operation: PTPOperationCode, _ parameters: UInt32...) {
        self.operation = operation
        self.parameters = parameters
    }

    /// The USB command container.  The transaction ID is written as 0: the
    /// system's PTP service owns the session and assigns its own.
    public var encoded: Data {
        var writer = ByteWriter()
        writer.write(UInt32(12 + 4 * parameters.count))
        writer.write(PTPContainerType.command.rawValue)
        writer.write(operation.rawValue)
        writer.write(UInt32(0))
        for parameter in parameters {
            writer.write(parameter)
        }
        return writer.data
    }
}

/// The camera's answer to a command.
public struct PTPResponse: Equatable, Sendable {
    public let code: PTPResponseCode
    public let parameters: [UInt32]

    public init(code: PTPResponseCode, parameters: [UInt32] = []) {
        self.code = code
        self.parameters = parameters
    }

    /// Decodes a USB response container.
    public init(container: Data) throws(ProtocolError) {
        let (code, parameters) = try decodeContainer(container, expecting: .response)
        self.init(code: PTPResponseCode(rawValue: code), parameters: parameters)
    }
}

/// Something the camera reports on its own, e.g. "properties changed".
public struct PTPEvent: Equatable, Sendable {
    public let code: PTPEventCode
    public let parameters: [UInt32]

    public init(code: PTPEventCode, parameters: [UInt32] = []) {
        self.code = code
        self.parameters = parameters
    }

    /// Decodes a USB event container.
    public init(container: Data) throws(ProtocolError) {
        let (code, parameters) = try decodeContainer(container, expecting: .event)
        self.init(code: PTPEventCode(rawValue: code), parameters: parameters)
    }
}

/// Header (length, type, code, transaction ID) followed by `UInt32`
/// parameters up to the container's stated length.
private func decodeContainer(_ data: Data, expecting type: PTPContainerType)
    throws(ProtocolError) -> (code: UInt16, parameters: [UInt32])
{
    var reader = ByteReader(data)
    let length = Int(try reader.read(UInt32.self))
    let containerType = try reader.read(UInt16.self)
    guard containerType == type.rawValue else { throw .unexpectedContainerType(containerType) }
    let code = try reader.read(UInt16.self)
    _ = try reader.read(UInt32.self)  // transaction ID
    let parameterBytes = min(length, data.count) - reader.offset
    var parameters: [UInt32] = []
    for _ in 0..<max(parameterBytes, 0) / 4 {
        parameters.append(try reader.read(UInt32.self))
    }
    return (code, parameters)
}
