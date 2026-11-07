import CameraFixtures
import Foundation
import Testing

@testable import SonyProtocol

/// Parsers run against real responses captured from an A6700 with an
/// E PZ 18-105mm F4 G OSS lens (Tests/CameraFixtures), so the expected values below are
/// what that camera reported, not values from documentation.
struct DatasetTests {
    // MARK: - GetAllExtDevicePropInfo

    @Test func parsesEveryPropertyOfTheRealDataset() throws {
        let descriptors = try PropertyDescriptor.parseAll(try Fixture.allProperties.data)
        #expect(descriptors.count == 351)
        #expect(Set(descriptors.map(\.code)).count == 351)
    }

    @Test func readsStringProperties() throws {
        let lens = try #require(try properties()[.lensModelName])
        #expect(lens.dataType == .string)
        #expect(lens.currentValue == .string("E PZ 18-105mm F4 G OSS"))
        #expect(!lens.isWritable)
    }

    @Test func readsRangeProperties() throws {
        let focalLength = try #require(try properties()[.focalLength])
        #expect(focalLength.dataType == .uint32)
        #expect(focalLength.currentValue == .unsigned(37_000))  // 37.0 mm in 0.001 mm units
        #expect(
            focalLength.constraint
                == .range(minimum: .unsigned(18_000), maximum: .unsigned(105_000), step: .unsigned(100)))
    }

    @Test func readsSignedValues() throws {
        let battery = try #require(try properties()[.batteryRemaining])
        #expect(battery.dataType == .int8)
        guard case .range(let minimum, _, _) = battery.constraint else {
            Issue.record("battery should be a range")
            return
        }
        #expect(minimum == .signed(-1))
    }

    @Test func separatesSettableFromSupportedValues() throws {
        // The mode dial owns the aperture while the camera has priority:
        // nothing is settable, but all values are listed.
        let aperture = try #require(try properties()[.fNumber])
        #expect(aperture.availability == .displayOnly)
        #expect(aperture.currentValue == .unsigned(400))  // f/4.0
        guard case .enumeration(let settable, let supported) = aperture.constraint else {
            Issue.record("aperture should be an enumeration")
            return
        }
        #expect(settable.isEmpty)
        #expect(supported.count == 16)
        #expect(supported.first == .unsigned(400))
    }

    @Test func listsBothPriorityKeyValues() throws {
        let priority = try #require(try properties()[.priorityKey])
        #expect(priority.isWritable)
        #expect(priority.currentValue == .unsigned(0))
        #expect(
            priority.constraint
                == .enumeration(settable: [.unsigned(0), .unsigned(1)], supported: [.unsigned(0), .unsigned(1)]))
    }

    // MARK: - SDIOGetExtDeviceInfo

    @Test func parsesExtendedDeviceInfo() throws {
        let info = try ExtendedDeviceInfo(try Fixture.extendedDeviceInfo.data)
        #expect(info.protocolVersion == 300)
        #expect(info.propertyCodes.count == 351)
        #expect(info.controlCodes.count == 57)
        #expect(info.controlCodes.contains(.zoomOperation))
        #expect(info.controlCodes.contains(.shutterFullPress))
    }

    // MARK: - Live view

    @Test func extractsTheLiveViewJPEG() throws {
        let image = try LiveViewImage(try Fixture.liveView.data)
        #expect(image.jpegData.prefix(2) == Data([0xFF, 0xD8]))
        #expect(image.jpegData.count > 50_000)
    }

    @Test func readsTheAFFrameOverTheLiveView() throws {
        // Recorded in Spot L: one contrast-AF frame, not focused, at (251, 159)
        // of the camera's 640×480 grid, 98 wide and 82 high.
        let image = try LiveViewImage(try Fixture.liveView.data)
        #expect(
            image.frames == [
                LiveViewFrame(
                    kind: .focus, type: 6, state: .notFocused, centre: .init(x: 251.0 / 640, y: 159.0 / 480),
                    width: 98.0 / 640, height: 82.0 / 480)
            ])
    }

    @Test func showsTheImageWhenTheFocusInfoIsUnreadable() throws {
        var data = try Fixture.liveView.data
        // The focus info's offset is the header's third field.
        let infoOffset = Int(data[8]) | Int(data[9]) << 8 | Int(data[10]) << 16 | Int(data[11]) << 24
        data.replaceSubrange(infoOffset..<infoOffset + 2, with: [0x10, 0x00])  // an older layout version
        #expect(try LiveViewImage(data).frames.isEmpty)
    }

    @Test func rejectsATruncatedLiveViewObject() throws {
        let data = try Fixture.liveView.data.prefix(1000)
        #expect(throws: ProtocolError.self) { try LiveViewImage(Data(data)) }
    }

    private func properties() throws -> [SonyPropertyCode: PropertyDescriptor] {
        let descriptors = try PropertyDescriptor.parseAll(try Fixture.allProperties.data)
        return Dictionary(uniqueKeysWithValues: descriptors.map { ($0.code, $0) })
    }
}
