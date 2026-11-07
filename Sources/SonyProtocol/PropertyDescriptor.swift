import Foundation

/// One device property from the camera's `GetAllExtDevicePropInfo` dataset:
/// its current value and what it may be set to.
public struct PropertyDescriptor: Equatable, Sendable {
    /// Whether the camera offers the property right now.
    public enum Availability: UInt8, Sendable {
        case disabled = 0
        case enabled = 1
        /// Shown but owned by the camera, e.g. exposure values while the mode
        /// dial has priority.
        case displayOnly = 2
    }

    /// The values the property may take.
    public enum Constraint: Equatable, Sendable {
        case none
        case range(minimum: PTPValue, maximum: PTPValue, step: PTPValue)
        /// `settable` are the values accepted right now — empty while the
        /// camera owns the property; `supported` are all values the camera
        /// knows.
        case enumeration(settable: [PTPValue], supported: [PTPValue])
    }

    public let code: SonyPropertyCode
    public let dataType: PTPDataType
    public let isWritable: Bool
    public let availability: Availability
    public let defaultValue: PTPValue
    public let currentValue: PTPValue
    public let constraint: Constraint
}

extension PropertyDescriptor {
    /// Parses a `GetAllExtDevicePropInfo` dataset: a `UInt64` entry count,
    /// then the entries back to back.
    public static func parseAll(_ data: Data) throws(ProtocolError) -> [PropertyDescriptor] {
        var reader = ByteReader(data)
        let count = try reader.read(UInt64.self)
        var descriptors: [PropertyDescriptor] = []
        for _ in 0..<count {
            descriptors.append(try PropertyDescriptor(reading: &reader))
        }
        guard reader.remaining == 0 else { throw .unexpectedTrailingData(count: reader.remaining) }
        return descriptors
    }

    /// Parses one entry: code, type, get/set flag, availability, default and
    /// current value, then the form (none / range / enumeration).
    init(reading reader: inout ByteReader) throws(ProtocolError) {
        code = SonyPropertyCode(rawValue: try reader.read(UInt16.self))
        let typeCode = try reader.read(UInt16.self)
        guard let dataType = PTPDataType(rawValue: typeCode) else { throw .unsupportedDataType(typeCode) }
        self.dataType = dataType
        isWritable = try reader.read(UInt8.self) == 1
        // Unknown availability values are treated as disabled rather than
        // failing the whole dataset.
        availability = Availability(rawValue: try reader.read(UInt8.self)) ?? .disabled
        defaultValue = try reader.readValue(of: dataType)
        currentValue = try reader.readValue(of: dataType)

        switch try reader.read(UInt8.self) {
        case 0:
            constraint = .none
        case 1:
            constraint = .range(
                minimum: try reader.readValue(of: dataType),
                maximum: try reader.readValue(of: dataType),
                step: try reader.readValue(of: dataType)
            )
        case 2:
            // Protocol 300 always sends two lists: what can be set right now,
            // then everything the camera supports.
            let settable = try Self.readList(of: dataType, from: &reader)
            let supported = try Self.readList(of: dataType, from: &reader)
            constraint = .enumeration(settable: settable, supported: supported)
        case let form:
            throw .unsupportedForm(form)
        }
    }

    private static func readList(of type: PTPDataType, from reader: inout ByteReader) throws(ProtocolError)
        -> [PTPValue]
    {
        let count = try reader.read(UInt16.self)
        var values: [PTPValue] = []
        values.reserveCapacity(Int(count))
        for _ in 0..<count {
            values.append(try reader.readValue(of: type))
        }
        return values
    }
}
