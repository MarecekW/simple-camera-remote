import Foundation
import ImageCaptureCore

/// Finds Sony cameras connected over USB.
///
/// ImageCaptureCore only reports devices to processes with a bundle identity
/// — an app, or an executable with an embedded Info.plist.
@MainActor
public final class CameraBrowser: NSObject {
    private static let sonyVendorID = 0x054C

    private struct Waiter {
        let continuation: CheckedContinuation<Void, Never>
        let deadline: Task<Void, Never>
    }

    private let browser = ICDeviceBrowser()
    /// Callers of `firstCamera` waiting for a camera or their deadline.
    private var waiters: [UUID: Waiter] = [:]

    /// Sony cameras currently attached.
    public private(set) var cameras: [ICCameraDevice] = []
    /// Called after a camera is attached or detached.
    public var onCamerasChanged: (() -> Void)?

    override public init() {
        super.init()
        // The delegate must be set before `start()`, or the browser ignores it.
        browser.delegate = self
        // Never nil: the imported initializer accepts any mask, it's only
        // optional because ICDeviceTypeMask is imported as an enum.
        browser.browsedDeviceTypeMask =
            ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)
            ?? .camera
    }

    public func start() { browser.start() }
    public func stop() { browser.stop() }

    /// The first Sony camera to appear, or nil after `timeout`.
    public func firstCamera(timeout: Duration) async -> ICCameraDevice? {
        if let camera = cameras.first { return camera }
        let id = UUID()
        // Whichever comes first — a camera or the deadline — wakes the
        // waiter, which then looks at `cameras` itself.
        await withCheckedContinuation { continuation in
            let deadline = Task {
                try? await Task.sleep(for: timeout)
                self.wake(id)
            }
            waiters[id] = Waiter(continuation: continuation, deadline: deadline)
        }
        return cameras.first
    }

    private func wake(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.deadline.cancel()
        waiter.continuation.resume()
    }

    private func add(_ camera: ICCameraDevice) {
        cameras.append(camera)
        for id in waiters.keys {
            wake(id)
        }
        onCamerasChanged?()
    }

    private func remove(_ device: ICDevice) {
        cameras.removeAll { $0 === device }
        onCamerasChanged?()
    }
}

// Browser callbacks arrive on the main thread, as documented — checked at
// run time by the isolated conformance's assertion.
// (PTP events don't; see PTPSession.)  ICCameraDevice isn't Sendable, so
// receiving it on the main actor is also what lets it stay there.
extension CameraBrowser: @MainActor ICDeviceBrowserDelegate {
    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice, camera.usbVendorID == Self.sonyVendorID else { return }
        add(camera)
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        remove(device)
    }
}
