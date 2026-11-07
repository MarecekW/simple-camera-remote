import Foundation

/// A malformed or truncated PTP dataset.
public enum ProtocolError: Error, Equatable, Sendable {
    /// Needed `needed` bytes at `offset`, but the data ends earlier.
    case truncated(offset: Int, needed: Int)
    /// A container's type field didn't match what was expected.
    case unexpectedContainerType(UInt16)
    /// A data type code this parser doesn't know how to read.
    case unsupportedDataType(UInt16)
    /// A value doesn't fit the property's data type.
    case valueOutOfRange
    /// A string where a number was expected, or the other way round.
    case typeMismatch
    /// A property dataset entry with a form this parser doesn't know; its
    /// size is unknown, so nothing after it can be read.
    case unsupportedForm(UInt8)
    /// Bytes left over after a dataset — the layout was misread.
    case unexpectedTrailingData(count: Int)
}

/// Reads PTP's little-endian primitives from a byte buffer, front to back.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset: Int

    init(_ data: Data, offset: Int = 0) {
        bytes = Array(data)
        self.offset = offset
    }

    var remaining: Int { bytes.count - offset }

    /// Continues reading at `offset` (reads past the end still throw).
    mutating func seek(to offset: Int) {
        self.offset = max(offset, 0)
    }

    mutating func read<Integer: FixedWidthInteger>(_: Integer.Type = Integer.self) throws(ProtocolError)
        -> Integer
    {
        let size = MemoryLayout<Integer>.size
        try require(size)
        var value = Integer.zero
        for index in 0..<size {
            value |= Integer(truncatingIfNeeded: bytes[offset + index]) << (8 * index)
        }
        offset += size
        return value
    }

    /// A PTP string: a byte holding the character count including the
    /// terminating NUL, then that many UTF-16LE code units.  Zero = empty.
    mutating func readString() throws(ProtocolError) -> String {
        let count = Int(try read(UInt8.self))
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for _ in 0..<count {
            units.append(try read(UInt16.self))
        }
        while units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    /// A PTP array: a `UInt32` element count, then the elements.
    mutating func readArray<Integer: FixedWidthInteger>(of _: Integer.Type) throws(ProtocolError) -> [Integer] {
        let count = Int(try read(UInt32.self))
        // Guard against a corrupt count asking for more than the data holds.
        try require(count * MemoryLayout<Integer>.size)
        var values: [Integer] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append(try read(Integer.self))
        }
        return values
    }

    mutating func readBytes(_ count: Int) throws(ProtocolError) -> Data {
        try require(count)
        defer { offset += count }
        return Data(bytes[offset..<offset + count])
    }

    private func require(_ count: Int) throws(ProtocolError) {
        guard count >= 0, remaining >= count else { throw .truncated(offset: offset, needed: count) }
    }
}

/// Writes PTP's little-endian primitives.
struct ByteWriter {
    private(set) var data = Data()

    mutating func write<Integer: FixedWidthInteger>(_ value: Integer) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
