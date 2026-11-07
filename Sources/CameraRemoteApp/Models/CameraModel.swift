import AppKit
import CaptureCore
import ImageCaptureCore
import Observation
import SonyProtocol
import SonyRemote

/// The connection to the camera: connects as soon as a Sony camera is
/// attached, follows it through unplugs and power cycles, and closes the
/// session when the app quits.
@MainActor
@Observable
final class CameraModel {
    enum ConnectionState: Equatable {
        case noCamera
        case connecting
        case connected
        /// The session ended or couldn't start; the message says what to do.
        case failed(String)
    }

    /// Who sets the exposure: the app, with the camera's mode dial and wheels
    /// locked, or the camera's dials, with the app showing their values.
    enum ExposureControl: String, CaseIterable {
        case app
        case cameraDials
    }

    /// Remembered, and applied whenever the camera connects.
    var exposureControl: ExposureControl {
        didSet {
            UserDefaults.standard.set(exposureControl.rawValue, forKey: Self.exposureControlKey)
            if !isTakingExposure { applyExposureControl() }
        }
    }
    /// Set while `takeExposure` applies the change itself.
    @ObservationIgnored private var isTakingExposure = false

    /// The attached camera, from the moment it's attached.
    private(set) var camera: SonyCamera?
    private var isConnecting = false
    private var failure: String?

    @ObservationIgnored private let browser = CameraBrowser()
    @ObservationIgnored private let messages: MessageLog
    @ObservationIgnored private var device: ICCameraDevice?

    private static let exposureControlKey = "camera-remote.exposureControl.v1"

    private static let handBackTimeout: Duration = .seconds(2)

    init(messages: MessageLog) {
        self.messages = messages
        exposureControl =
            UserDefaults.standard.string(forKey: Self.exposureControlKey).flatMap(ExposureControl.init) ?? .app
        browser.onCamerasChanged = { [weak self] in self?.camerasChanged() }
        browser.start()
        // The model lives as long as the app, so the observer is never removed.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.camera?.disconnect() }
        }
    }

    var state: ConnectionState {
        guard let camera else { return .noCamera }
        if camera.isConnected { return .connected }
        if isConnecting { return .connecting }
        return .failed(failure ?? camera.sessionEndReason.map(Self.message(for:)) ?? Self.closedMessage)
    }

    /// Gives the camera's dials back for as long as the app is gone, so the
    /// camera isn't left with dead dials (called when quitting).
    func handBackDials() async {
        guard let camera, camera.isConnected, camera.hasPCPriority else { return }
        // Quitting waits for this, but not long: a camera that doesn't
        // answer mustn't keep the app open.
        await withCheckedContinuation { continuation in
            let finish = FirstFinish(continuation)
            Task {
                do {
                    try await camera.setPCPriority(false, remember: false)
                } catch {
                    Log.ptp.error("handing back the dials failed: \(String(describing: error), privacy: .public)")
                }
                finish()
            }
            Task {
                try? await Task.sleep(for: Self.handBackTimeout)
                finish()
            }
        }
    }

    /// Tries again with the attached camera, e.g. after a failure.
    func reconnect() {
        guard let camera else { return }
        connect(camera)
    }

    // MARK: - Private

    private static let closedMessage = "The camera closed the connection."

    private func camerasChanged() {
        if let device, !browser.cameras.contains(where: { $0 === device }) {
            Log.ptp.info("camera detached")
            camera?.disconnect()
            camera = nil
            self.device = nil
        }
        if device == nil, let attached = browser.cameras.first {
            // One SonyCamera — and so one PTP session — per attached device,
            // for as long as it stays attached.
            device = attached
            let camera = SonyCamera(device: attached)
            camera.prefersPCPriority = exposureControl == .app
            self.camera = camera
            connect(camera)
        }
    }

    /// Gives the app the exposure, as choosing App does, and waits until
    /// the camera has handed it over (a preset sets the exposure mode next).
    func takeExposure(on camera: SonyCamera) async throws {
        isTakingExposure = true
        exposureControl = .app
        isTakingExposure = false
        try await camera.takePCPriority()
    }

    private func applyExposureControl() {
        guard let camera else { return }
        let isPC = exposureControl == .app
        guard camera.isConnected else {
            // Applied when it connects.
            camera.prefersPCPriority = isPC
            return
        }
        Task {
            do {
                try await camera.setPCPriority(isPC)
                try await camera.refreshProperties()
            } catch {
                messages.post(.failure, "The camera didn't switch who sets the exposure.")
                Log.ptp.error("changing priority failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func connect(_ camera: SonyCamera) {
        isConnecting = true
        failure = nil
        Log.ptp.info("connecting to \(camera.name, privacy: .public)")
        Task {
            var outcome: String?
            do {
                try await camera.connect()
                Log.ptp.info("connected")
            } catch is CancellationError {
                // A disconnect or a newer attempt took over.
                return
            } catch {
                Log.ptp.error("connect failed: \(String(describing: error), privacy: .public)")
                outcome = Self.message(for: error)
            }
            guard self.camera === camera else { return }
            failure = outcome
            isConnecting = false
        }
    }

    /// What the user can do about a failure, in plain words.
    private static func message(for error: any Error) -> String {
        switch error {
        case SonyCameraError.staleSession:
            "The camera is still holding an old session. Unplug the USB cable and plug it back in."
        case SonyCameraError.unsupportedProtocol:
            "This camera speaks an older remote-control protocol that this app doesn't support."
        case PTPSessionError.timedOut, PTPSessionError.openFailed:
            "The camera didn't answer. Check that it's in Remote Shoot (PC Remote) mode, then reconnect."
        case PTPSessionError.deviceRemoved:
            "The camera was disconnected."
        default:
            // The details are in the log (category "ptp").
            "Lost contact with the camera. Check the cable and that the camera is on, then reconnect."
        }
    }
}

/// Resumes a continuation once, for whichever of several tasks finishes
/// first.
@MainActor
private final class FirstFinish {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func callAsFunction() {
        continuation?.resume()
        continuation = nil
    }
}
