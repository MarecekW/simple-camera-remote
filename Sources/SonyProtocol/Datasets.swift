import Foundation

/// The answer to `SDIOGetExtDeviceInfo`: the protocol version the camera
/// speaks and the property and control codes it supports.
public struct ExtendedDeviceInfo: Equatable, Sendable {
    /// Requested and answered as a version number, e.g. 300 (`0x012C`).
    public let protocolVersion: UInt16
    public let propertyCodes: [SonyPropertyCode]
    public let controlCodes: [SonyControlCode]

    public init(_ data: Data) throws(ProtocolError) {
        var reader = ByteReader(data)
        protocolVersion = try reader.read(UInt16.self)
        propertyCodes = try reader.readArray(of: UInt16.self).map(SonyPropertyCode.init(rawValue:))
        controlCodes = try reader.readArray(of: UInt16.self).map(SonyControlCode.init(rawValue:))
    }
}

/// A live-view object (`GetObject` on `ObjectHandle.liveView`): a header
/// locating the JPEG and the focus-frame data inside the object.
public struct LiveViewImage: Equatable, Sendable {
    public let jpegData: Data
    /// The AF frames, faces and tracked subjects the camera reports.
    public let frames: [LiveViewFrame]

    public init(_ data: Data) throws(ProtocolError) {
        // One reader over the object, which arrives 30 times a second.
        var reader = ByteReader(data)
        let jpegOffset = Int(try reader.read(UInt32.self))
        let jpegSize = Int(try reader.read(UInt32.self))
        let info = try? (offset: Int(reader.read(UInt32.self)), size: Int(reader.read(UInt32.self)))
        reader.seek(to: jpegOffset)
        jpegData = try reader.readBytes(jpegSize)
        // The frames are a bonus: an object without (or with unreadable)
        // focus info still has its image.
        if let info {
            reader.seek(to: info.offset)
            frames = (try? reader.readBytes(info.size)).map(LiveViewFrame.parse(focusInfo:)) ?? []
        } else {
            frames = []
        }
    }
}

/// The standard PTP ObjectInfo dataset (PIMA 15740 §5.5.2), as returned for
/// a captured image.
public struct ObjectInfo: Equatable, Sendable {
    public let format: UInt16
    public let compressedSize: UInt32
    public let imageWidth: UInt32
    public let imageHeight: UInt32
    public let filename: String

    public init(_ data: Data) throws(ProtocolError) {
        var reader = ByteReader(data)
        _ = try reader.read(UInt32.self)  // storage ID
        format = try reader.read(UInt16.self)
        _ = try reader.read(UInt16.self)  // protection status
        compressedSize = try reader.read(UInt32.self)
        _ = try reader.read(UInt16.self)  // thumbnail format
        _ = try reader.read(UInt32.self)  // thumbnail size
        _ = try reader.read(UInt32.self)  // thumbnail width
        _ = try reader.read(UInt32.self)  // thumbnail height
        imageWidth = try reader.read(UInt32.self)
        imageHeight = try reader.read(UInt32.self)
        _ = try reader.read(UInt32.self)  // bit depth
        _ = try reader.read(UInt32.self)  // parent object
        _ = try reader.read(UInt16.self)  // association type
        _ = try reader.read(UInt32.self)  // association description
        _ = try reader.read(UInt32.self)  // sequence number
        filename = try reader.readString()
    }
}
