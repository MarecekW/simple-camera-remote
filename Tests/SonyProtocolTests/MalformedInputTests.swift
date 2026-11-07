import Foundation
import Testing

@testable import SonyProtocol

/// Inputs the camera shouldn't send, but a parser must survive: every one
/// fails with a `ProtocolError` instead of misreading or trapping.
struct MalformedInputTests {
    @Test func rejectsATruncatedContainerHeader() {
        #expect(throws: ProtocolError.self) { try PTPResponse(container: Data([0x0C, 0, 0, 0, 0x03, 0])) }
    }

    @Test func readsOnlyTheParametersThatArePresent() throws {
        // The header claims 20 bytes (two parameters), but only one arrived.
        let container = Data([0x14, 0, 0, 0, 0x03, 0, 0x01, 0x20, 0, 0, 0, 0, 0x2A, 0, 0, 0])
        #expect(try PTPResponse(container: container).parameters == [42])
    }

    @Test func rejectsAnArrayCountLargerThanTheData() {
        var writer = ByteWriter()
        writer.write(UInt16(300))  // protocol version
        writer.write(UInt32(1_000_000))  // property code count
        writer.write(UInt16(0x5007))
        #expect(throws: ProtocolError.self) { try ExtendedDeviceInfo(writer.data) }
    }

    @Test func rejectsTrailingBytesAfterAPropertyDataset() {
        var dataset = propertyDataset(form: 0)
        dataset.append(0xFF)
        #expect(throws: ProtocolError.unexpectedTrailingData(count: 1)) { try PropertyDescriptor.parseAll(dataset) }
    }

    @Test func rejectsAnUnknownPropertyForm() {
        #expect(throws: ProtocolError.unsupportedForm(7)) { try PropertyDescriptor.parseAll(propertyDataset(form: 7)) }
    }

    @Test func rejectsAnUnknownDataType() {
        var writer = ByteWriter()
        writer.write(UInt64(1))
        writer.write(UInt16(0x5007))
        writer.write(UInt16(0x0009))  // INT128 — not used by Sony, not supported
        #expect(throws: ProtocolError.unsupportedDataType(9)) { try PropertyDescriptor.parseAll(writer.data) }
    }

    /// One UINT8 property (F-number code) with the given form byte and no
    /// form data.
    private func propertyDataset(form: UInt8) -> Data {
        var writer = ByteWriter()
        writer.write(UInt64(1))  // entry count
        writer.write(UInt16(0x5007))  // code
        writer.write(PTPDataType.uint8.rawValue)
        writer.write(UInt8(1))  // get/set
        writer.write(UInt8(1))  // enabled
        writer.write(UInt8(2))  // default
        writer.write(UInt8(3))  // current
        writer.write(form)
        return writer.data
    }
}

struct ValueEncodingTests {
    @Test func encodesTheLimitsOfEachWidth() throws {
        #expect(try PTPValue.signed(-128).encoded(as: .int8) == Data([0x80]))
        #expect(try PTPValue.unsigned(UInt64.max).encoded(as: .uint64) == Data(repeating: 0xFF, count: 8))
        #expect(try PTPValue.signed(Int64.min).encoded(as: .int64) == Data([0, 0, 0, 0, 0, 0, 0, 0x80]))
    }

    @Test func refusesValuesThatDoNotFit() {
        #expect(throws: ProtocolError.valueOutOfRange) { try PTPValue.signed(-1).encoded(as: .uint16) }
        #expect(throws: ProtocolError.valueOutOfRange) { try PTPValue.signed(128).encoded(as: .int8) }
        #expect(throws: ProtocolError.valueOutOfRange) { try PTPValue.unsigned(UInt64.max).encoded(as: .int64) }
    }

    @Test func refusesStringsAndStringTypes() {
        #expect(throws: ProtocolError.typeMismatch) { try PTPValue.string("x").encoded(as: .uint8) }
        #expect(throws: ProtocolError.typeMismatch) { try PTPValue.unsigned(1).encoded(as: .string) }
    }
}

struct ObjectInfoTests {
    @Test func readsTheFilenameAndFormatOfACapturedImage() throws {
        var writer = ByteWriter()
        writer.write(UInt32(0x0001_0001))  // storage ID
        writer.write(UInt16(0xB101))  // ARW
        writer.write(UInt16(0))  // protection
        writer.write(UInt32(28_758_016))  // size
        writer.write(UInt16(0))  // thumbnail format
        for _ in 0..<3 { writer.write(UInt32(0)) }  // thumbnail size, width, height
        writer.write(UInt32(6192))  // width
        writer.write(UInt32(4128))  // height
        for _ in 0..<2 { writer.write(UInt32(0)) }  // bit depth, parent
        writer.write(UInt16(0))  // association type
        for _ in 0..<2 { writer.write(UInt32(0)) }  // association description, sequence
        let name = Array("DSC01134.ARW".utf16) + [0]
        writer.write(UInt8(name.count))
        for unit in name { writer.write(unit) }

        let info = try ObjectInfo(writer.data)
        #expect(info.filename == "DSC01134.ARW")
        #expect(info.format == 0xB101)
        #expect(info.compressedSize == 28_758_016)
        #expect(info.imageWidth == 6192)
    }
}

struct CodeNameTests {
    @Test func everyTableHasUniqueNames() {
        #expect(Set(PTPOperationCode.names.values).count == PTPOperationCode.names.count)
        #expect(Set(PTPResponseCode.names.values).count == PTPResponseCode.names.count)
        #expect(Set(PTPEventCode.names.values).count == PTPEventCode.names.count)
        #expect(Set(SonyPropertyCode.names.values).count == SonyPropertyCode.names.count)
        #expect(Set(SonyControlCode.names.values).count == SonyControlCode.names.count)
    }

    @Test func unknownCodesPrintAsHex() {
        #expect(SonyPropertyCode.focalLength.description == "FocalLength")
        #expect(SonyPropertyCode(rawValue: 0xABCD).description == "0xABCD")
    }
}
