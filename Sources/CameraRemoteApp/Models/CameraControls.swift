import CaptureCore
import Foundation
import Observation
import SonyProtocol
import SonyRemote

/// Changing camera settings, from the inspector and the keyboard alike.
///
/// A value just asked for shows at once and is the base for the next step,
/// so holding a stepper or a key walks through the values even though the
/// camera reports each change a moment later.
@MainActor
@Observable
final class CameraControls {
    /// Guards a dataset's exposure against a stray click or keypress.
    var isExposureLocked: Bool {
        didSet { UserDefaults.standard.set(isExposureLocked, forKey: Self.exposureLockKey) }
    }

    /// Whether a capture is running: it owns the shutter, so autofocus and
    /// zoom wait.  Set by the app.
    @ObservationIgnored var isCapturing: @MainActor () -> Bool = { false }

    /// Values asked for that the camera hasn't reported yet.
    private var pending: [SonyPropertyCode: PTPValue] = [:]
    /// The camera whose half press the AF button or its key holds.
    @ObservationIgnored private var focusHeldOn: SonyCamera?
    private var isHoldingFocus: Bool { focusHeldOn != nil }
    @ObservationIgnored private var focusSteps: Task<Void, Never>?
    /// Set while a zoom started by holding is running.
    @ObservationIgnored private var isZoomHeld = false
    @ObservationIgnored private let messages: MessageLog

    // Zoom speeds measured on the SELP18105G (docs/HARDWARE_NOTES.md).
    static let slowZoomSpeed: Int8 = 1
    static let fastZoomSpeed: Int8 = 4

    /// How long a value asked for is shown before the camera's own report
    /// takes over again.
    private static let pendingLifetime: Duration = .seconds(1.5)
    private static let exposureLockKey = "camera-remote.exposure.locked.v1"

    /// The settings the exposure lock covers.
    static let exposureCodes: Set<SonyPropertyCode> = [
        .exposureProgramMode, .fNumber, .shutterSpeed, .isoSensitivity, .exposureCompensation,
    ]

    init(messages: MessageLog) {
        self.messages = messages
        isExposureLocked = UserDefaults.standard.bool(forKey: Self.exposureLockKey)
    }

    /// The value to show: the one just asked for, else the camera's.
    func value(of code: SonyPropertyCode, on camera: SonyCamera) -> PTPValue? {
        pending[code] ?? camera.properties[code]?.currentValue
    }

    /// The values `code` can be set to now, in the camera's order (the order
    /// of its dial); empty when the camera or the exposure lock owns it.
    func choices(for code: SonyPropertyCode, on camera: SonyCamera) -> [PTPValue] {
        guard !isLocked(code), let descriptor = camera.properties[code], descriptor.isWritable,
            descriptor.availability == .enabled
        else { return [] }
        switch descriptor.constraint {
        case .enumeration(let settable, _):
            let current = value(of: code, on: camera)
            return settable.filter { $0 == current || CameraSettingFormat.isOffered($0, of: code) }
        case .range(let minimum, let maximum, let step):
            guard let low = minimum.integerValue, let high = maximum.integerValue, let increment = step.integerValue,
                low <= high
            else { return [] }
            let isSigned = descriptor.dataType.isSigned
            return stride(from: low, through: high, by: Int(max(increment, 1))).map {
                // An unsigned range starts at 0 or above, so the conversion holds.
                isSigned ? .signed($0) : .unsigned(UInt64($0))
            }
        case .none:
            return []
        }
    }

    func isLocked(_ code: SonyPropertyCode) -> Bool {
        isExposureLocked && Self.exposureCodes.contains(code)
    }

    /// Moves `code` `offset` places along its choices, stopping at the ends.
    /// A value outside the choices (set on the camera in another mode) has
    /// no place to step from; the menu still offers every choice.
    ///
    /// Exposure compensation steps by value, so + brightens: the camera
    /// lists it from +5.0 down.
    func step(_ code: SonyPropertyCode, by offset: Int, on camera: SonyCamera) {
        var options = choices(for: code, on: camera)
        if code == .exposureCompensation {
            options.sort { ($0.integerValue ?? 0) < ($1.integerValue ?? 0) }
        }
        guard let current = value(of: code, on: camera), let index = options.firstIndex(of: current) else { return }
        let target = min(max(index + offset, 0), options.count - 1)
        guard target != index else { return }
        set(code, to: options[target], on: camera)
    }

    func set(_ code: SonyPropertyCode, to value: PTPValue, on camera: SonyCamera) {
        guard !isLocked(code) else { return }
        pending[code] = value
        Task {
            do {
                // Checked against the camera's list as it is now, not as it
                // was when the value was offered: a dial or an earlier
                // setting may have changed it since.
                guard camera.properties[code]?.accepts(value) == true else {
                    throw SonyCameraError.valueNotOffered(code, value)
                }
                try await camera.setProperty(code, to: value)
            } catch {
                if pending[code] == value { pending[code] = nil }
                messages.post(.failure, "The camera didn't accept \(CameraSettingFormat.display(value, of: code)).")
                Log.ptp.error(
                    "setting \(code, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                return
            }
            try? await Task.sleep(for: Self.pendingLifetime)
            if pending[code] == value { pending[code] = nil }
        }
    }

    /// The shutter's half press while held, exactly as on the camera: in AF
    /// modes it focuses; in MF it doesn't focus but steadies the image (the
    /// stabiliser wakes up).  The focus mode is never changed.  Never during
    /// a capture, whose own half press a release here would cut short (the
    /// capture releases it itself).
    ///
    /// Returns whether a press was taken up.  A hold on a camera that has
    /// since disconnected is let go of without a word: that half press ended
    /// with the connection.
    @discardableResult
    func autofocus(_ isPressed: Bool, on camera: SonyCamera) -> Bool {
        if let held = focusHeldOn, held !== camera || !held.isConnected { focusHeldOn = nil }
        if isPressed {
            guard !isHoldingFocus, !isHandlingClick, !isCapturing() else { return false }
            focusHeldOn = camera
            runInOrder { try await camera.press(.shutterHalfPress) }
            return true
        } else {
            guard isHoldingFocus else { return false }
            focusHeldOn = nil
            guard !isCapturing() else { return false }
            runInOrder { try await camera.release(.shutterHalfPress) }
            return false
        }
    }

    /// Runs focus steps one after another, so a quick release can't overtake
    /// its press.
    private func runInOrder(_ steps: @escaping @MainActor () async throws -> Void) {
        let previous = focusSteps
        focusSteps = Task {
            await previous?.value
            do {
                try await steps()
            } catch {
                messages.post(.failure, "The camera didn't autofocus.")
                Log.ptp.error("autofocus failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Whether a live-view click is focusing — the shutter waits for it, as
    /// each would cut the other's half press short.  Holding AF doesn't
    /// block the shutter: focusing with AF and then shooting is a normal way
    /// to work, and a capture's half press is never released from here.
    var isUsingShutter: Bool { isHandlingClick }

    /// Ends whatever a held button started — called when the mouse button
    /// comes up anywhere, in case the button itself missed the release.
    func releaseHeldButtons(on camera: SonyCamera) {
        autofocus(false, on: camera)
        if isZoomHeld { zoom(speed: 0, on: camera) }
    }

    /// Set while a click on the live view is being handled (focusing there
    /// or moving the magnifier); further clicks wait.
    private(set) var isHandlingClick = false
    /// The magnification last asked for, until the camera reports it — so a
    /// quick second press of the magnifier goes on to the next ratio.
    @ObservationIgnored private var requestedMagnification: Double??
    /// Set while a focus step is on its way, so a held button doesn't queue
    /// steps that keep moving focus after it's let go.
    @ObservationIgnored private var isSteppingFocus = false

    /// A click on the live view at `point` (0…1 of the image).  Magnified,
    /// it moves the magnified area there.  In AF the AF point moves there and
    /// the camera focuses.  In MF focus is the user's: a click only magnifies
    /// there, to check it (as touching the camera's screen does), and never
    /// autofocuses — the AF button is the way to autofocus in MF.
    func liveViewClicked(at point: LiveViewPoint, frames: [LiveViewFrame], on camera: SonyCamera) {
        guard !isCapturing(), !isHandlingClick, !isHoldingFocus else { return }
        if let ratio = camera.magnification {
            handleClick("The magnifier didn't move.") { try await camera.magnify(ratio, at: camera.unmagnified(point)) }
        } else if !camera.isAutofocusing {
            guard let ratio = camera.magnifierRatios.first else { return }
            handleClick("The camera didn't magnify.") {
                try await camera.magnify(ratio, at: point)
                try await camera.refreshProperties()
            }
        } else {
            let frame = frames.first { $0.kind == .focus }
            handleClick("The camera didn't focus there.") { [messages] in
                if try await camera.moveAFPoint(to: point, keepingInside: frame) != nil {
                    messages.post(.info, "Focus area set to Spot so the AF point can move.")
                }
                if try await camera.focusOnce() == .noFocus {
                    messages.post(.warning, "Couldn't focus there — try a spot with more contrast.")
                }
            }
        }
    }

    private func handleClick(_ failure: String, _ work: @escaping @MainActor () async throws -> Void) {
        isHandlingClick = true
        Task {
            defer { isHandlingClick = false }
            do {
                try await work()
            } catch {
                messages.post(.failure, failure)
                Log.ptp.error("live-view click failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Moves manual focus one step nearer (negative) or farther; MF and DMF.
    func stepFocus(_ step: Int16, on camera: SonyCamera) {
        guard !isCapturing(), !isSteppingFocus else { return }
        isSteppingFocus = true
        Task {
            defer { isSteppingFocus = false }
            do {
                try await camera.stepFocus(step)
            } catch {
                messages.post(.failure, "The camera didn't move focus.")
                Log.ptp.error("focus step failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Magnifies the live view `ratio` times (around the AF point, where the
    /// camera starts), or ends magnifying at nil.  Not during a capture.
    func setMagnification(_ ratio: Double?, on camera: SonyCamera) {
        guard !isCapturing() else { return }
        requestedMagnification = .some(ratio)
        Task {
            defer { requestedMagnification = nil }
            do {
                if let ratio {
                    try await camera.magnify(ratio)
                } else {
                    try await camera.endMagnification()
                }
                try await camera.refreshProperties()
            } catch {
                messages.post(.failure, "The camera didn't change the magnification.")
                Log.ptp.error("magnifier failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The next step of the magnifier button: off → each ratio → off.
    func cycleMagnification(on camera: SonyCamera) {
        let ratios = camera.magnifierRatios
        guard !ratios.isEmpty else { return }
        let current = requestedMagnification ?? camera.magnification
        let next: Double? = if let current { ratios.first { $0 > current } } else { ratios.first }
        setMagnification(next, on: camera)
    }

    /// Starts zooming (negative speeds towards wide), or stops at speed 0.
    /// Doesn't start during a capture.
    func zoom(speed: Int8, on camera: SonyCamera) {
        if speed != 0, isCapturing() { return }
        isZoomHeld = speed != 0
        Task {
            do {
                if speed == 0 {
                    try await camera.stopZoom()
                    try? await camera.refreshProperties()
                } else {
                    try await camera.startZoom(speed: speed)
                }
            } catch {
                messages.post(.failure, "The zoom didn't respond.")
                Log.ptp.error("zoom failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
