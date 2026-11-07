import Foundation

// The protocol's code spaces as open structs rather than enums: a camera can
// always send a code we don't know (Sony adds properties with every body), and
// it must survive the round trip.  Named members are the codes the app uses or
// meets on the wire; values are from the camera's own lists
// (docs/HARDWARE_NOTES.md) and libgphoto2's ptp.h.

/// A code with names for logging; unknown codes print as hex.
public protocol PTPCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible
where RawValue == UInt16 {
    static var names: [Self: String] { get }
}

extension PTPCode {
    public var description: String { Self.names[self] ?? String(format: "0x%04X", rawValue) }
}

// MARK: - Operations

public struct PTPOperationCode: PTPCode {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// Opened by the system's PTP service on our behalf; named for reporting.
    public static let openSession = Self(rawValue: 0x1002)
    public static let getObjectInfo = Self(rawValue: 0x1008)
    public static let getObject = Self(rawValue: 0x1009)
    // Sony vendor operations ("SDIO").
    public static let sdioConnect = Self(rawValue: 0x9201)
    public static let sdioGetExtDeviceInfo = Self(rawValue: 0x9202)
    public static let setExtDevicePropValue = Self(rawValue: 0x9205)
    public static let controlDevice = Self(rawValue: 0x9207)
    public static let getAllExtDevicePropInfo = Self(rawValue: 0x9209)

    public static let names: [Self: String] = [
        .openSession: "OpenSession",
        .getObjectInfo: "GetObjectInfo",
        .getObject: "GetObject",
        .sdioConnect: "SDIOConnect",
        .sdioGetExtDeviceInfo: "SDIOGetExtDeviceInfo",
        .setExtDevicePropValue: "SetExtDevicePropValue",
        .controlDevice: "ControlDevice",
        .getAllExtDevicePropInfo: "GetAllExtDevicePropInfo",
    ]
}

// MARK: - Responses

public struct PTPResponseCode: PTPCode {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let ok = Self(rawValue: 0x2001)
    public static let generalError = Self(rawValue: 0x2002)
    public static let sessionNotOpen = Self(rawValue: 0x2003)
    public static let operationNotSupported = Self(rawValue: 0x2005)
    public static let parameterNotSupported = Self(rawValue: 0x2006)
    public static let incompleteTransfer = Self(rawValue: 0x2007)
    public static let invalidObjectHandle = Self(rawValue: 0x2009)
    public static let accessDenied = Self(rawValue: 0x200F)
    public static let deviceBusy = Self(rawValue: 0x2019)
    public static let invalidDevicePropFormat = Self(rawValue: 0x201B)
    public static let invalidDevicePropValue = Self(rawValue: 0x201C)
    public static let sessionAlreadyOpen = Self(rawValue: 0x201E)

    public static let names: [Self: String] = [
        .ok: "OK",
        .generalError: "GeneralError",
        .sessionNotOpen: "SessionNotOpen",
        .operationNotSupported: "OperationNotSupported",
        .parameterNotSupported: "ParameterNotSupported",
        .incompleteTransfer: "IncompleteTransfer",
        .invalidObjectHandle: "InvalidObjectHandle",
        .accessDenied: "AccessDenied",
        .deviceBusy: "DeviceBusy",
        .invalidDevicePropFormat: "InvalidDevicePropFormat",
        .invalidDevicePropValue: "InvalidDevicePropValue",
        .sessionAlreadyOpen: "SessionAlreadyOpen",
    ]
}

// MARK: - Events

public struct PTPEventCode: PTPCode {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let objectAdded = Self(rawValue: 0xC201)
    public static let objectRemoved = Self(rawValue: 0xC202)
    public static let propertiesChanged = Self(rawValue: 0xC203)
    public static let captured = Self(rawValue: 0xC206)
    public static let displayListChanged = Self(rawValue: 0xC20F)

    public static let names: [Self: String] = [
        .objectAdded: "ObjectAdded",
        .objectRemoved: "ObjectRemoved",
        .propertiesChanged: "PropertiesChanged",
        .captured: "Captured",
        .displayListChanged: "DisplayListChanged",
    ]
}

// MARK: - Device properties

/// A Sony device property, read with `GetAllExtDevicePropInfo` and written
/// with `SetExtDevicePropValue`.
public struct SonyPropertyCode: PTPCode {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    // Exposure
    public static let exposureProgramMode = Self(rawValue: 0x500E)
    public static let fNumber = Self(rawValue: 0x5007)
    public static let shutterSpeed = Self(rawValue: 0xD20D)
    public static let isoSensitivity = Self(rawValue: 0xD21E)
    public static let exposureCompensation = Self(rawValue: 0x5010)
    public static let whiteBalance = Self(rawValue: 0x5005)
    public static let colorTemperature = Self(rawValue: 0xD20F)
    public static let dynamicRangeOptimizer = Self(rawValue: 0xD201)
    // Focus and drive
    public static let focusMode = Self(rawValue: 0x500A)
    public static let focusArea = Self(rawValue: 0xD22C)
    public static let focusIndication = Self(rawValue: 0xD213)
    public static let focusMagnifier = Self(rawValue: 0xD254)
    public static let driveMode = Self(rawValue: 0x5013)
    // Image
    public static let fileFormat = Self(rawValue: 0xD253)
    public static let jpegQuality = Self(rawValue: 0xD252)
    public static let imageSize = Self(rawValue: 0xD203)
    public static let aspectRatio = Self(rawValue: 0xD211)
    /// The format of the second file in RAW+JPEG/HEIF: 1 = JPEG.
    public static let compressionFileFormat = Self(rawValue: 0xD287)
    public static let rawCompression = Self(rawValue: 0xD288)
    public static let lensCompensationShading = Self(rawValue: 0xD1A2)
    public static let lensCompensationChromaticAberration = Self(rawValue: 0xD1A3)
    public static let lensCompensationDistortion = Self(rawValue: 0xD1A4)
    // Remote control and transfer
    public static let priorityKey = Self(rawValue: 0xD25A)
    public static let stillImageStoreDestination = Self(rawValue: 0xD222)
    public static let pcSaveImage = Self(rawValue: 0xD269)
    public static let pcSaveImageSize = Self(rawValue: 0xD268)
    public static let objectsInMemory = Self(rawValue: 0xD215)
    public static let liveViewQuality = Self(rawValue: 0xD26A)
    public static let liveViewStatus = Self(rawValue: 0xD221)
    /// Whether live view shows the exposure settings' effect: read only.
    public static let liveViewSettingEffect = Self(rawValue: 0xD231)
    // Zoom
    public static let focalLength = Self(rawValue: 0xD00B)
    public static let zoomSetting = Self(rawValue: 0xD25F)
    public static let zoomOperationEnabled = Self(rawValue: 0xD25B)
    public static let zoomSpeedRange = Self(rawValue: 0xD25E)
    public static let zoomDrivingStatus = Self(rawValue: 0xD19D)
    public static let zoomPositionSetting = Self(rawValue: 0xE040)
    public static let zoomPositionCurrentValue = Self(rawValue: 0xE041)
    // Status
    public static let batteryRemaining = Self(rawValue: 0xD218)
    public static let usbPowerSupply = Self(rawValue: 0xD150)
    public static let mediaSlot1Status = Self(rawValue: 0xD248)
    public static let mediaSlot1RemainingShots = Self(rawValue: 0xD249)
    public static let lensModelName = Self(rawValue: 0xD07B)

    public static let names: [Self: String] = [
        .exposureProgramMode: "ExposureProgramMode",
        .fNumber: "FNumber",
        .shutterSpeed: "ShutterSpeed",
        .isoSensitivity: "ISOSensitivity",
        .exposureCompensation: "ExposureCompensation",
        .whiteBalance: "WhiteBalance",
        .colorTemperature: "ColorTemperature",
        .dynamicRangeOptimizer: "DynamicRangeOptimizer",
        .focusMode: "FocusMode",
        .focusArea: "FocusArea",
        .focusIndication: "FocusIndication",
        .focusMagnifier: "FocusMagnifier",
        .driveMode: "DriveMode",
        .fileFormat: "FileFormat",
        .jpegQuality: "JPEGQuality",
        .imageSize: "ImageSize",
        .aspectRatio: "AspectRatio",
        .compressionFileFormat: "CompressionFileFormat",
        .rawCompression: "RAWCompression",
        .lensCompensationShading: "LensCompensationShading",
        .lensCompensationChromaticAberration: "LensCompensationChromaticAberration",
        .lensCompensationDistortion: "LensCompensationDistortion",
        .priorityKey: "PriorityKey",
        .stillImageStoreDestination: "StillImageStoreDestination",
        .pcSaveImage: "PCSaveImage",
        .pcSaveImageSize: "PCSaveImageSize",
        .objectsInMemory: "ObjectsInMemory",
        .liveViewQuality: "LiveViewQuality",
        .liveViewStatus: "LiveViewStatus",
        .liveViewSettingEffect: "LiveViewSettingEffect",
        .focalLength: "FocalLength",
        .zoomSetting: "ZoomSetting",
        .zoomOperationEnabled: "ZoomOperationEnabled",
        .zoomSpeedRange: "ZoomSpeedRange",
        .zoomDrivingStatus: "ZoomDrivingStatus",
        .zoomPositionSetting: "ZoomPositionSetting",
        .zoomPositionCurrentValue: "ZoomPositionCurrentValue",
        .batteryRemaining: "BatteryRemaining",
        .usbPowerSupply: "USBPowerSupply",
        .mediaSlot1Status: "MediaSlot1Status",
        .mediaSlot1RemainingShots: "MediaSlot1RemainingShots",
        .lensModelName: "LensModelName",
    ]
}

// MARK: - Controls

/// A button or action, sent with `ControlDevice`.
public struct SonyControlCode: PTPCode {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let shutterHalfPress = Self(rawValue: 0xD2C1)
    public static let shutterFullPress = Self(rawValue: 0xD2C2)
    public static let manualFocusStep = Self(rawValue: 0xD2D1)
    public static let afAreaPosition = Self(rawValue: 0xD2DC)
    public static let zoomOperation = Self(rawValue: 0xD2DD)
    public static let saveZoomAndFocusPosition = Self(rawValue: 0xD2E9)
    public static let loadZoomAndFocusPosition = Self(rawValue: 0xD2EA)
    public static let cancelZoomPosition = Self(rawValue: 0xF00C)

    public static let names: [Self: String] = [
        .shutterHalfPress: "ShutterHalfPress",
        .shutterFullPress: "ShutterFullPress",
        .manualFocusStep: "ManualFocusStep",
        .afAreaPosition: "AFAreaPosition",
        .zoomOperation: "ZoomOperation",
        .saveZoomAndFocusPosition: "SaveZoomAndFocusPosition",
        .loadZoomAndFocusPosition: "LoadZoomAndFocusPosition",
        .cancelZoomPosition: "CancelZoomPosition",
    ]
}

/// The value sent with a button control.
public enum ButtonState: UInt16, Sendable {
    case up = 1
    case down = 2
}

// MARK: - Objects

/// Sony's fixed object handles for camera-memory objects.
public struct ObjectHandle: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// The oldest captured image waiting in camera memory.
    public static let capturedImage = Self(rawValue: 0xFFFF_C001)
    public static let liveView = Self(rawValue: 0xFFFF_C002)
}
