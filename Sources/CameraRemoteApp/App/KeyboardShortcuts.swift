import AppKit
import SonyProtocol
import SonyRemote

/// Single-key camera shortcuts, after Sony Remote: hold W / T to zoom (⇧
/// fast), hold A to autofocus, S F I E to step shutter, aperture, ISO and
/// exposure compensation (⇧ steps back), ] and [ for the next and previous
/// side.  On top of those, the keys chosen in Settings → Shortcuts
/// (`ShortcutBindings`): shoot, focus, the magnifier, review and the sample
/// workflow's steps, e.g. from a wireless numpad.
///
/// Handled with an event monitor rather than menu key equivalents, because
/// these need key-up as well, and must never fire while a text field — in
/// any window — is being typed into.
@MainActor
final class KeyboardShortcuts {
    /// A zoom or half press started by holding a key, ended by its
    /// release.  The key is told by its code: what it types can change with
    /// a modifier pressed or let go meanwhile.
    private struct Hold {
        enum Kind { case zoom, halfPress }

        let keyCode: UInt16
        let kind: Kind
        let camera: SonyCamera
    }

    private let camera: CameraModel
    private let capture: CaptureModel
    private let controls: CameraControls
    private let bindings: ShortcutBindings
    private let review: ReviewModel
    private let liveView: LiveViewModel
    private let messages: MessageLog
    /// The monitor and observers last as long as the app, so they're never
    /// removed.
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var hold: Hold?
    /// Set from a Shoot key press until its capture starts: a Focus press
    /// in between would half-press under the starting capture.
    private var isShotPending = false

    init(
        camera: CameraModel, capture: CaptureModel, controls: CameraControls, bindings: ShortcutBindings,
        review: ReviewModel, liveView: LiveViewModel, messages: MessageLog
    ) {
        self.liveView = liveView
        self.camera = camera
        self.capture = capture
        self.controls = controls
        self.bindings = bindings
        self.review = review
        self.messages = messages
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseUp]) {
            [weak self] event in
            // Local monitors run on the main thread.
            let isHandled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return isHandled ? nil : event
        }
        // A key released in another app or window never reaches the monitor:
        // end the hold when this app or its window loses the keyboard.
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.endHold() }
                })
        }
    }

    /// Whether `event` was a shortcut, consumed.
    private func handle(_ event: NSEvent) -> Bool {
        if event.type == .leftMouseUp {
            // A safety net for the hold buttons (AF, zoom): whatever they
            // started ends with the mouse button, even if a view missed the
            // release.  Never consumed; a key's own hold stays its own.
            if hold == nil, let sonyCamera = camera.camera {
                controls.releaseHeldButtons(on: sonyCamera)
            }
            return false
        }
        let key = event.charactersIgnoringModifiers?.lowercased()
        // The release of a held key always ends its hold, whatever changed
        // since the press (a modifier, the focus, the connection).
        if event.type == .keyUp {
            guard let hold, hold.keyCode == event.keyCode else { return false }
            endHold()
            return true
        }

        // While Settings records a key, nothing fires.  Nor behind a sheet or
        // alert: a shot taken under a "Delete…?" dialog would change what it
        // deletes, and the welcome sheet shows before the camera is set up.
        guard bindings.recordingAction == nil, !(event.window?.firstResponder is NSText), !capture.isEditingText,
            NSApp.modalWindow == nil, event.window?.attachedSheet == nil, event.window?.isSheet != true
        else { return false }
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
            let action = bindings.action(for: event.keyCode)
        {
            if !event.isARepeat || action.repeatsWhileHeld {
                perform(action, keyCode: event.keyCode, isRepeat: event.isARepeat)
            }
            return true
        }
        guard let key, let sonyCamera = camera.camera, camera.state == .connected,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return false }
        let isShifted = event.modifierFlags.contains(.shift)

        switch key {
        case "w", "t":
            // As the inspector's zoom buttons: only while the camera allows
            // zooming with this lens.
            guard !event.isARepeat, hold == nil, sonyCamera.isZoomAvailable else { return true }
            hold = Hold(keyCode: event.keyCode, kind: .zoom, camera: sonyCamera)
            let speed = isShifted ? CameraControls.fastZoomSpeed : CameraControls.slowZoomSpeed
            controls.zoom(speed: key == "w" ? -speed : speed, on: sonyCamera)
        case "a":
            guard !event.isARepeat, hold == nil else { return true }
            if controls.autofocus(true, on: sonyCamera) {
                hold = Hold(keyCode: event.keyCode, kind: .halfPress, camera: sonyCamera)
            }
        case "s", "f", "i", "e":
            let code: SonyPropertyCode =
                switch key {
                case "s": .shutterSpeed
                case "f": .fNumber
                case "i": .isoSensitivity
                default: .exposureCompensation
                }
            controls.step(code, by: isShifted ? -1 : 1, on: sonyCamera)
        case "]", "}":
            guard let side = capture.session.sample?.side else { return false }
            capture.setSide(side + 1)
        case "[", "{":
            guard let side = capture.session.sample?.side else { return false }
            capture.setSide(side - 1)
        default:
            return false
        }
        return true
    }

    /// A key chosen in Settings, pressed.  Each says why when it can't act:
    /// whoever pressed it may be across the room from the screen.
    private func perform(_ action: ShortcutBindings.Action, keyCode: UInt16, isRepeat: Bool) {
        switch action {
        case .shoot:
            if let reason = capture.blockedReason {
                messages.post(.warning, "Not shot: \(reason)")
                capture.playSound(.failed)
            } else if !isShotPending {
                isShotPending = true
                Task {
                    isShotPending = false
                    await capture.shoot()
                }
            }
        case .focus:
            // Held like the AF button and A: the half press lasts until the
            // key comes up.
            guard hold == nil, !isShotPending, let sonyCamera = connectedCameraOrWarn() else { return }
            // Only a press taken up is this key's to release: not one the AF
            // button already holds, nor one refused mid-capture.
            if controls.autofocus(true, on: sonyCamera) {
                hold = Hold(keyCode: keyCode, kind: .halfPress, camera: sonyCamera)
            }
        case .focusNearer, .focusFarther:
            guard let sonyCamera = isRepeat ? camera.camera : connectedCameraOrWarn() else { return }
            // The camera's small and medium steps (docs/HARDWARE_NOTES.md).
            let size = SonyCamera.manualFocusSteps[isRepeat ? 1 : 0]
            controls.stepFocus(action == .focusNearer ? -size : size, on: sonyCamera)
        case .magnify:
            guard let sonyCamera = connectedCameraOrWarn() else { return }
            controls.cycleMagnification(on: sonyCamera)
        case .review:
            // As the toolbar's Review: only with a JPEG to show.
            guard review.isShown || capture.lastCapture?.jpeg != nil else { return }
            review.isShown.toggle()
        case .nextSide, .previousSide:
            guard let side = capture.session.sample?.side, !capture.isCapturing else { return }
            capture.setSide(side + (action == .nextSide ? 1 : -1))
        case .nextLoad:
            guard capture.session.sample != nil, !capture.isCapturing else { return }
            capture.startNextLoad()
        case .grid: liveView.showsGrid.toggle()
        case .centre: liveView.showsCrosshair.toggle()
        case .histogram: liveView.showsHistogram.toggle()
        case .peaking: liveView.showsPeaking.toggle()
        case .rulers: liveView.showsRulers.toggle()
        }
    }

    private func connectedCameraOrWarn() -> SonyCamera? {
        guard let sonyCamera = camera.camera, camera.state == .connected else {
            messages.post(.warning, "The camera isn't connected.")
            return nil
        }
        return sonyCamera
    }

    private func endHold() {
        guard let hold else { return }
        self.hold = nil
        if hold.kind == .halfPress {
            controls.autofocus(false, on: hold.camera)
        } else {
            controls.zoom(speed: 0, on: hold.camera)
        }
    }
}
