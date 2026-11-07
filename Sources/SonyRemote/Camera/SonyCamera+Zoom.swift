import Foundation
import SonyProtocol

/// Power zoom (docs/HARDWARE_NOTES.md, "Power zoom"): speed-driven, since the
/// A6700 offers no absolute zoom position; the focal length reads back in
/// whole millimetres.
extension SonyCamera {
    public enum ZoomError: Error, Equatable, Sendable {
        /// The lens isn't a power zoom, or the camera doesn't allow zooming now.
        case unavailable
        /// The focal length stopped changing before the target was reached
        /// (e.g. the end of the zoom range).
        case stalled(atThousandthsOfMillimetre: UInt32)
        /// Not one of `zoomAndFocusPresetSlots`; never sent.
        case unsupportedSlot(UInt8)
        /// Outside `zoomSpeeds`; never sent.
        case unsupportedSpeed(Int8)
    }

    /// The camera's zoom-and-focus preset slots.  Any other slot crashes the
    /// A6700 (docs/HARDWARE_NOTES.md), so none is ever sent.
    public nonisolated static let zoomAndFocusPresetSlots: ClosedRange<UInt8> = 1...3

    /// The zoom speeds the A6700 reports (docs/HARDWARE_NOTES.md, "Power
    /// zoom"), for a camera that reports none.
    public nonisolated static let defaultZoomSpeeds: ClosedRange<Int8> = -8...8

    /// Focal length in thousandths of a millimetre.
    public var focalLength: UInt32? {
        properties[.focalLength]?.currentValue.bitPattern.map { UInt32(truncatingIfNeeded: $0) }
    }

    /// The focal-length range the lens reports, in thousandths of a millimetre.
    public var focalLengthRange: ClosedRange<UInt32>? {
        guard case .range(let minimum, let maximum, _) = properties[.focalLength]?.constraint,
            let low = minimum.bitPattern, let high = maximum.bitPattern, low <= high
        else { return nil }
        return UInt32(truncatingIfNeeded: low)...UInt32(truncatingIfNeeded: high)
    }

    /// The zoom speeds the camera takes, from the range it reports for
    /// `0xD25E` (−8…8 on the A6700); −8…8 if it reports none.
    public var zoomSpeeds: ClosedRange<Int8> {
        guard case .range(let minimum, let maximum, _) = properties[.zoomSpeedRange]?.constraint,
            let low = minimum.integerValue.flatMap(Int8.init(exactly:)),
            let high = maximum.integerValue.flatMap(Int8.init(exactly:)), low <= high
        else { return Self.defaultZoomSpeeds }
        return low...high
    }

    /// Whether the camera allows zoom operation (`0xD25B` = 1) with this lens.
    public var isZoomAvailable: Bool {
        properties[.zoomOperationEnabled]?.currentValue == .unsigned(1)
    }

    /// Starts zooming: positive speeds towards tele, negative towards wide;
    /// the lens moves until `stopZoom()`.  Never sent while the camera
    /// doesn't allow zooming (`ZoomError.unavailable`), nor at a speed
    /// outside `zoomSpeeds`; stopping always is.
    public func startZoom(speed: Int8) async throws {
        guard isZoomAvailable else { throw ZoomError.unavailable }
        guard zoomSpeeds.contains(speed) else { throw ZoomError.unsupportedSpeed(speed) }
        try await perform(.zoomOperation, value: .signed(Int64(speed)), as: .int8)
    }

    public func stopZoom() async throws {
        try await perform(.zoomOperation, value: .signed(0), as: .int8)
    }

    /// Zooms to `target` (thousandths of a millimetre): fast while far away,
    /// then slowly for the last few millimetres, since the fast speed coasts
    /// ~2 mm after stopping and the slow one doesn't.  No change for
    /// `stallTimeout` while driving means the lens hit an end.  Returns the
    /// focal length reached, within the lens' 1 mm readout.
    @discardableResult
    public func zoom(
        to target: UInt32, pollInterval: Duration = .milliseconds(150), stallTimeout: Duration = .seconds(2)
    ) async throws -> UInt32 {
        guard let start = focalLength else { throw ZoomError.unavailable }
        let towardsTele = target > start
        var current = start
        var lastChange = ContinuousClock.now
        var speed: Int8 = 0
        do {
            while towardsTele ? current < target : current > target {
                let distance = towardsTele ? target - current : current - target
                let wanted: Int8 = distance > Self.slowApproachDistance ? Self.fastZoomSpeed : Self.slowZoomSpeed
                if wanted != speed {
                    speed = wanted
                    try await startZoom(speed: towardsTele ? speed : -speed)
                }
                try await Task.sleep(for: pollInterval)
                try await refreshProperties()
                guard let reading = focalLength else { throw ZoomError.unavailable }
                if reading != current {
                    current = reading
                    lastChange = .now
                } else if ContinuousClock.now - lastChange > stallTimeout {
                    throw ZoomError.stalled(atThousandthsOfMillimetre: current)
                }
            }
        } catch {
            // Never leave the lens driving.
            try? await stopZoom()
            throw error
        }
        try await stopZoom()
        try await refreshProperties()
        return focalLength ?? current
    }

    /// Stores the current zoom and focus position in one of the camera's
    /// preset slots (kept in the camera, even through a reset).
    public func saveZoomAndFocusPreset(_ slot: UInt8) async throws {
        guard Self.zoomAndFocusPresetSlots.contains(slot) else { throw ZoomError.unsupportedSlot(slot) }
        try await perform(.saveZoomAndFocusPosition, value: .unsigned(UInt64(slot)), as: .uint8)
    }

    /// Moves zoom and focus to a saved preset — the exact lens position, finer
    /// than the 1 mm focal-length readout.
    public func loadZoomAndFocusPreset(_ slot: UInt8) async throws {
        guard Self.zoomAndFocusPresetSlots.contains(slot) else { throw ZoomError.unsupportedSlot(slot) }
        try await perform(.loadZoomAndFocusPosition, value: .unsigned(UInt64(slot)), as: .uint8)
    }

    // Speeds and distances measured on the SELP18105G.
    private static let fastZoomSpeed: Int8 = 4
    private static let slowZoomSpeed: Int8 = 1
    private static let slowApproachDistance: UInt32 = 4_000
}
