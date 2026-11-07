import Foundation
import Testing

@testable import SonyProtocol

struct ContainerTests {
    @Test func encodesACommandContainer() {
        let command = PTPCommand(.sdioConnect, 1, 0, 0)
        #expect(
            command.encoded
                == Data([
                    0x18, 0x00, 0x00, 0x00,  // length 24
                    0x01, 0x00,  // command
                    0x01, 0x92,  // 0x9201
                    0x00, 0x00, 0x00, 0x00,  // transaction ID, assigned by the system
                    0x01, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00,
                ]))
    }

    @Test func decodesAResponseFromTheCamera() throws {
        // GetExtDeviceInfo's response as captured: OK, one parameter.
        let container = Data([0x10, 0, 0, 0, 0x03, 0, 0x01, 0x20, 0x0F, 0, 0, 0, 0x36, 0x01, 0, 0])
        let response = try PTPResponse(container: container)
        #expect(response.code == .ok)
        #expect(response.parameters == [0x136])
    }

    @Test func rejectsAContainerOfTheWrongType() {
        let event = Data([0x0C, 0, 0, 0, 0x04, 0, 0x03, 0xC2, 0, 0, 0, 0])
        #expect(throws: ProtocolError.unexpectedContainerType(4)) { try PTPResponse(container: event) }
    }

    @Test func decodesAnEvent() throws {
        let container = Data([0x10, 0, 0, 0, 0x04, 0, 0x03, 0xC2, 0, 0, 0, 0, 0x13, 0xD2, 0, 0])
        let event = try PTPEvent(container: container)
        #expect(event.code == .propertiesChanged)
        #expect(event.parameters == [0xD213])
    }

    @Test func encodesValuesInThePropertyType() throws {
        #expect(try PTPValue.unsigned(1).encoded(as: .uint8) == Data([0x01]))
        #expect(try PTPValue.signed(-1000).encoded(as: .int16) == Data([0x18, 0xFC]))
        #expect(try PTPValue.unsigned(0x0001_03E8).encoded(as: .uint32) == Data([0xE8, 0x03, 0x01, 0x00]))
        #expect(throws: ProtocolError.valueOutOfRange) { try PTPValue.unsigned(300).encoded(as: .uint8) }
    }
}
