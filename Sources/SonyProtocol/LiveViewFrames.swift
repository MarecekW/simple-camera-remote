import Foundation

/// A point on the live-view image, 0…1 across and down.
public struct LiveViewPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let centre = LiveViewPoint(x: 0.5, y: 0.5)
}

/// A frame the camera draws over its live view — an AF frame, a face, a
/// tracked subject — as reported in the live-view object's focus-info block
/// (docs/HARDWARE_NOTES.md, Focus).  Position and size are fractions of the
/// live-view image, so they map onto it however it's displayed.
public struct LiveViewFrame: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case focus, face, tracking
    }

    /// How the camera shows the frame (`CrFocusFrameState`).
    public struct State: RawRepresentable, Hashable, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        public static let notFocused = Self(rawValue: 1)
        /// Drawn green by the camera.
        public static let focused = Self(rawValue: 2)
        /// Being selected or moved (orange).
        public static let selecting = Self(rawValue: 3)
        public static let moving = Self(rawValue: 4)
    }

    public let kind: Kind
    /// The camera's frame type (e.g. 6, a contrast-AF flexible spot).
    public let type: UInt16
    public let state: State
    public let centre: LiveViewPoint
    /// The frame's size, as fractions of the image's width and height.
    public let width: Double
    public let height: Double

    public init(kind: Kind, type: UInt16, state: State, centre: LiveViewPoint, width: Double, height: Double) {
        self.kind = kind
        self.type = type
        self.state = state
        self.centre = centre
        self.width = width
        self.height = height
    }
}

extension LiveViewFrame {
    /// The frames in a live-view focus-info block.  The layout (from the
    /// A6700's own data): a version, a level block when the version is above
    /// 0x67, then blocks of frames — an unused one, focus frames, faces,
    /// tracking — each a header (x and y denominators, a count) and 24-byte
    /// entries.  Whatever can't be read ends the list; the image is still
    /// worth showing without frames.
    public static func parse(focusInfo data: Data) -> [LiveViewFrame] {
        var reader = ByteReader(data)
        guard let version = try? reader.read(UInt16.self), version > layoutVersion else { return [] }
        reader.seek(to: firstBlockOffset)
        var frames: [LiveViewFrame] = []
        for kind in blockKinds {
            guard let block = try? readBlock(&reader, kind: kind) else { break }
            frames += block
        }
        return frames
    }

    private static func readBlock(_ reader: inout ByteReader, kind: Kind?) throws(ProtocolError) -> [LiveViewFrame] {
        let xDenominator = Double(try reader.read(UInt32.self))
        let yDenominator = Double(try reader.read(UInt32.self))
        let count = try reader.read(UInt16.self)
        _ = try reader.readBytes(6)
        var frames: [LiveViewFrame] = []
        for _ in 0..<count {
            let type = try reader.read(UInt16.self)
            let state = try reader.read(UInt16.self)
            _ = try reader.read(UInt32.self)  // priority
            let x = Double(try reader.read(UInt32.self))
            let y = Double(try reader.read(UInt32.self))
            // Height comes before width: a Zone frame, wider than tall on the
            // camera's screen, reads 238 then 302 (docs/HARDWARE_NOTES.md).
            let height = Double(try reader.read(UInt32.self))
            let width = Double(try reader.read(UInt32.self))
            guard let kind, xDenominator > 0, yDenominator > 0 else { continue }
            frames.append(
                LiveViewFrame(
                    kind: kind, type: type, state: State(rawValue: state),
                    centre: LiveViewPoint(x: x / xDenominator, y: y / yDenominator),
                    width: width / xDenominator, height: height / yDenominator))
        }
        return frames
    }

    /// Versions above this have the level block before the frames.
    private static let layoutVersion: UInt16 = 0x67
    private static let firstBlockOffset = 0x28
    /// The blocks in order; the first isn't used yet (possibly the
    /// magnifier's position).
    private static let blockKinds: [Kind?] = [nil, .focus, .face, .tracking]
}
