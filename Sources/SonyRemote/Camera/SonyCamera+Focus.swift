import Foundation
import SonyProtocol

/// Focusing on a point of the live view, manual focus and the focus
/// magnifier (docs/HARDWARE_NOTES.md, Focus).  Points are fractions of the
/// live-view image; the camera takes them on an abstract 640×480 grid over
/// that image.
extension SonyCamera {
    public enum FocusResult: Equatable, Sendable {
        case focused
        case noFocus
    }

    // MARK: - AF point

    /// Moves the AF frame's centre to `point`, kept far enough inside the
    /// image for `frame` (the live view's current AF frame) to fit.  A focus
    /// area without a movable frame is switched first — Wide or Center Fix
    /// to Spot M, their tracking versions to Tracking: Spot M — and that new
    /// area is returned; if the camera doesn't offer that area now, nothing
    /// is sent (`SonyCameraError.valueNotOffered`).  Doesn't focus.
    @discardableResult
    public func moveAFPoint(to point: LiveViewPoint, keepingInside frame: LiveViewFrame? = nil) async throws
        -> UInt64?
    {
        var frame = frame
        var switchedArea: UInt64?
        if let area = properties[.focusArea]?.currentValue.bitPattern, let spot = FocusAreaValue.replacement(for: area)
        {
            let spotValue = PTPValue.unsigned(spot)
            guard properties[.focusArea]?.accepts(spotValue) == true else {
                throw SonyCameraError.valueNotOffered(.focusArea, spotValue)
            }
            try await setProperty(.focusArea, to: spotValue)
            try await waitForProperty(.focusArea, toBe: spotValue)
            switchedArea = spot
            // The old area's frame says nothing about the new one's size.
            frame = nil
        }
        let x = Self.gridCoordinate(point.x, size: Self.grid.width, frame: frame?.width ?? 0)
        let y = Self.gridCoordinate(point.y, size: Self.grid.height, frame: frame?.height ?? 0)
        try await perform(.afAreaPosition, value: .unsigned(UInt64(x) << 16 | UInt64(y)), as: .uint32)
        return switchedArea
    }

    /// Whether the focus area's AF frame can be moved as it is (Zone, the
    /// spots and their tracking versions) — not Wide or Center Fix.
    public var hasMovableAFFrame: Bool {
        guard let area = properties[.focusArea]?.currentValue.bitPattern else { return false }
        return FocusAreaValue.replacement(for: area) == nil
    }

    /// Focuses once, as a half press does, and lets go.  Like the camera,
    /// it doesn't autofocus in MF (throws `SonyCameraError.manualFocus`):
    /// focus there is the user's.
    @discardableResult
    public func focusOnce(timeout: Duration = .seconds(4), pollInterval: Duration = .milliseconds(50))
        async throws -> FocusResult
    {
        guard isAutofocusing else { throw SonyCameraError.manualFocus }
        let result: FocusResult
        do {
            try await press(.shutterHalfPress)
            try await waitForFocus(timeout: timeout, pollInterval: pollInterval)
            result = .focused
        } catch let error as CaptureError where error.reason == .noFocus {
            result = .noFocus
        } catch {
            // Never leave the shutter half-pressed.
            try? await release(.shutterHalfPress)
            throw error
        }
        try await release(.shutterHalfPress)
        return result
    }

    // MARK: - Manual focus

    /// Focus steps the camera takes, as Sony Remote offers them: small,
    /// medium and large (`0xD2D1`).
    public nonisolated static let manualFocusSteps: [Int16] = [1, 3, 7]

    /// Whether `step` is one of `manualFocusSteps`, either way.
    public nonisolated static func isManualFocusStep(_ step: Int16) -> Bool {
        manualFocusSteps.contains { $0 == step || -$0 == step }
    }

    /// Moves focus one step nearer (negative) or farther (positive); works
    /// in MF and DMF.  Only `manualFocusSteps` (either way) are ever sent
    /// (`SonyCameraError.unsupportedFocusStep`): only these are verified.
    public func stepFocus(_ step: Int16) async throws {
        guard Self.isManualFocusStep(step) else {
            throw SonyCameraError.unsupportedFocusStep(step)
        }
        try await perform(.manualFocusStep, value: .signed(Int64(step)), as: .int16)
    }

    // MARK: - Focus magnifier

    /// The magnifications the camera offers (e.g. 6.1 and 12.1), from its
    /// list of magnifier values; ×1.0 and off aren't magnifications.  The
    /// list of all supported values, not the settable one: the A6700 reports
    /// the magnifier display-only with nothing settable, yet takes these
    /// values (docs/HARDWARE_NOTES.md, "Focus magnifier").
    public var magnifierRatios: [Double] {
        guard case .enumeration(_, let supported) = properties[.focusMagnifier]?.constraint else { return [] }
        return supported.compactMap { value in
            value.bitPattern.map { Double($0 >> 32) / 10 }.flatMap { $0 > 1 ? $0 : nil }
        }
    }

    /// The current magnification, or nil while not magnified.
    public var magnification: Double? {
        guard let value = properties[.focusMagnifier]?.currentValue.bitPattern else { return nil }
        let ratio = Double(value >> 32) / 10
        return ratio > 1 ? ratio : nil
    }

    /// The centre of the magnified area, while magnified; the image's
    /// centre if the camera doesn't say.
    public var magnifierCentre: LiveViewPoint? {
        guard magnification != nil, let value = properties[.focusMagnifier]?.currentValue.bitPattern else {
            return nil
        }
        guard value & Self.keepPosition != Self.keepPosition else { return .centre }
        return LiveViewPoint(
            x: Double((value >> 16) & 0xFFFF) / Double(Self.grid.width),
            y: Double(value & 0xFFFF) / Double(Self.grid.height))
    }

    /// The point of the full image under `point` of the magnified live view.
    public func unmagnified(_ point: LiveViewPoint) -> LiveViewPoint {
        guard let ratio = magnification, let centre = magnifierCentre else { return point }
        return LiveViewPoint(x: centre.x + (point.x - 0.5) / ratio, y: centre.y + (point.y - 0.5) / ratio)
    }

    /// Magnifies the live view `ratio` times around `point` (or where the
    /// camera last magnified).  The camera places a position reliably only
    /// once magnified, so it enters first and then moves.  A ratio the
    /// camera doesn't list is never sent (`SonyCameraError.valueNotOffered`).
    public func magnify(_ ratio: Double, at point: LiveViewPoint? = nil) async throws {
        let ratioField = UInt64((ratio * 10).rounded()) << 32
        // The list holds each ratio with "no new position"; positions within
        // a listed ratio are the verified encoding, not a list to check.
        let entry = PTPValue.unsigned(ratioField | Self.keepPosition)
        guard case .enumeration(_, let supported) = properties[.focusMagnifier]?.constraint,
            supported.contains(entry)
        else { throw SonyCameraError.valueNotOffered(.focusMagnifier, entry) }
        let wasMagnified = magnification != nil
        if !wasMagnified || point == nil {
            try await setProperty(.focusMagnifier, to: .unsigned(ratioField | Self.keepPosition))
        }
        guard let point else { return }
        if !wasMagnified { try await waitForMagnification() }
        let x = Self.gridCoordinate(point.x, size: Self.grid.width, frame: 1 / ratio)
        let y = Self.gridCoordinate(point.y, size: Self.grid.height, frame: 1 / ratio)
        try await setProperty(.focusMagnifier, to: .unsigned(ratioField | UInt64(x) << 16 | UInt64(y)))
    }

    public func endMagnification() async throws {
        try await setProperty(.focusMagnifier, to: .unsigned(Self.keepPosition))
    }

    // MARK: - Private

    /// The camera's coordinate grid over the live-view image.
    private static let grid = (width: 640, height: 480)
    /// The lower half of a magnifier value meaning "no new position".
    private static let keepPosition: UInt64 = 0xFFFF_FFFF

    /// `fraction` of the way across a grid side of `size`, kept half a
    /// frame (`frame`, a fraction of the side) away from the edges.
    /// Fractions outside 0…1 are taken as the nearest edge, and a fraction
    /// or frame that isn't a number as none — a preset file can hold
    /// anything, and converting a huge value to `Int` would trap.
    static func gridCoordinate(_ fraction: Double, size: Int, frame: Double) -> Int {
        let fraction = fraction.isFinite ? min(max(fraction, 0), 1) : 0.5
        let frame = frame.isFinite ? min(max(frame, 0), 1) : 0
        // A frame can't be wider than the grid, whatever the camera reports.
        let margin = min(Int((frame * Double(size) / 2).rounded(.up)), size / 2)
        let value = Int((fraction * Double(size)).rounded(.down))
        return min(max(value, margin), max(margin, size - 1 - margin))
    }

    /// Re-reads the properties until `code` reads `value`; the camera takes
    /// a moment to apply some changes.
    func waitForProperty(
        _ code: SonyPropertyCode, toBe value: PTPValue, timeout: Duration = .seconds(1)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try await refreshProperties()
            if properties[code]?.currentValue == value { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SonyCameraError.settingNotApplied(code)
    }

    private func waitForMagnification(timeout: Duration = .seconds(1)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try await refreshProperties()
            if magnification != nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SonyCameraError.settingNotApplied(.focusMagnifier)
    }
}

/// Focus area (`0xD22C`) values (docs/PROPERTY_VALUES.md).
enum FocusAreaValue {
    /// Areas without a movable frame, and the spot area each switches to:
    /// Wide and Center Fix to Spot M, their tracking versions to Tracking:
    /// Spot M, so tracking stays on.
    private static let replacements: [UInt64: UInt64] = [0x001: 0x102, 0x003: 0x102, 0x201: 0x205, 0x203: 0x205]

    /// The area to switch to before moving the AF point, or nil if `area`'s
    /// frame moves (Zone, the spots and their tracking versions).
    static func replacement(for area: UInt64) -> UInt64? {
        replacements[area]
    }
}
