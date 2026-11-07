import Foundation

/// PTP's data type codes (PIMA 15740 §5.3), as used in property datasets.
public enum PTPDataType: UInt16, Sendable {
    case int8 = 0x0001
    case uint8 = 0x0002
    case int16 = 0x0003
    case uint16 = 0x0004
    case int32 = 0x0005
    case uint32 = 0x0006
    case int64 = 0x0007
    case uint64 = 0x0008
    case string = 0xFFFF

    /// Whether values of this type are read as `.signed`.
    public var isSigned: Bool {
        switch self {
        case .int8, .int16, .int32, .int64: true
        case .uint8, .uint16, .uint32, .uint64, .string: false
        }
    }
}

/// One property value as the camera sends it.
public enum PTPValue: Hashable, Sendable {
    case signed(Int64)
    case unsigned(UInt64)
    case string(String)

    /// The value as a 64-bit pattern, for numeric values.
    public var bitPattern: UInt64? {
        switch self {
        case .signed(let value): UInt64(bitPattern: value)
        case .unsigned(let value): value
        case .string: nil
        }
    }

    public var integerValue: Int64? {
        switch self {
        case .signed(let value): value
        case .unsigned(let value): Int64(exactly: value)
        case .string: nil
        }
    }
}

extension ByteReader {
    mutating func readValue(of type: PTPDataType) throws(ProtocolError) -> PTPValue {
        switch type {
        case .int8: .signed(Int64(try read(Int8.self)))
        case .uint8: .unsigned(UInt64(try read(UInt8.self)))
        case .int16: .signed(Int64(try read(Int16.self)))
        case .uint16: .unsigned(UInt64(try read(UInt16.self)))
        case .int32: .signed(Int64(try read(Int32.self)))
        case .uint32: .unsigned(UInt64(try read(UInt32.self)))
        case .int64: .signed(try read(Int64.self))
        case .uint64: .unsigned(try read(UInt64.self))
        case .string: .string(try readString())
        }
    }
}

extension PTPValue {
    /// The value's bytes in `type`, as `SetExtDevicePropValue` expects them.
    /// Throws when the value doesn't fit the type.
    public func encoded(as type: PTPDataType) throws(ProtocolError) -> Data {
        var writer = ByteWriter()
        switch (type, self) {
        case (.string, _), (_, .string):
            throw .typeMismatch
        case (.int8, _): writer.write(try narrow(Int8.self))
        case (.uint8, _): writer.write(try narrow(UInt8.self))
        case (.int16, _): writer.write(try narrow(Int16.self))
        case (.uint16, _): writer.write(try narrow(UInt16.self))
        case (.int32, _): writer.write(try narrow(Int32.self))
        case (.uint32, _): writer.write(try narrow(UInt32.self))
        case (.int64, _): writer.write(try narrow(Int64.self))
        case (.uint64, _): writer.write(try narrow(UInt64.self))
        }
        return writer.data
    }

    private func narrow<Integer: FixedWidthInteger>(_: Integer.Type) throws(ProtocolError) -> Integer {
        let narrowed: Integer? =
            switch self {
            case .signed(let value): Integer(exactly: value)
            case .unsigned(let value): Integer(exactly: value)
            case .string: nil
            }
        guard let narrowed else { throw .valueOutOfRange }
        return narrowed
    }
}
