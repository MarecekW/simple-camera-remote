import Foundation
import ImageCaptureCore
import Observation
import SonyProtocol

/// A Sony camera in PC Remote mode, driven with Sony's vendor PTP operations.
///
/// Once connected it keeps `properties` current on its own: it re-reads them
/// when the camera reports a change, and every few seconds in case a change
/// goes unreported.
@MainActor
@Observable
public final class SonyCamera {
    /// The protocol version requested in the handshake: 300, spoken by
    /// bodies from 2020 on, which take absolute property values.  The
    /// property parser assumes it.
    public static let protocolVersion: UInt16 = 300

    /// Priority-key values: the PC sets exposure mode, aperture, shutter and
    /// ISO, and the camera's mode dial and wheels do nothing for them — or
    /// the dials are in charge and the PC can only read those values.
    private static let pcPriority = PTPValue.unsigned(1)
    private static let cameraPriority = PTPValue.unsigned(0)
    /// `SDIOConnect` answer of a camera still holding the session of a
    /// client that vanished; only a replug clears it.
    private static let staleSessionResponse = PTPResponseCode(rawValue: 0xA101)
    /// How long the shutter button is held fully down: long enough for the
    /// camera to release (docs/HARDWARE_NOTES.md).
    private static let shutterPressDuration: Duration = .milliseconds(100)
    /// How often a capture asks whether its next file is ready.
    private static let capturedFilePollInterval: Duration = .milliseconds(100)

    /// Whether connecting gives the PC priority over the camera's dials.
    public var prefersPCPriority = true

    public let name: String
    /// The body's serial number, as the system reports it.
    public let serialNumber: String?
    @ObservationIgnored public let transport: any PTPTransport
    public private(set) var deviceInfo: ExtendedDeviceInfo?
    /// Every property as last reported by the camera.
    public private(set) var properties: [SonyPropertyCode: PropertyDescriptor] = [:]
    /// True from a completed handshake until the session ends.
    public private(set) var isConnected = false
    /// Why the last session ended on its own, if it did.
    public private(set) var sessionEndReason: (any Error)?

    /// How often properties are re-read when the camera reports nothing.
    @ObservationIgnored private let pollingInterval: Duration
    /// Bumped by every connect and disconnect, so a connect that a
    /// disconnect overtook doesn't come back to life when its awaits finish.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var monitoringTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var isRefreshing = false
    /// Callers waiting for the read after the running one.
    @ObservationIgnored private var refreshWaiters: [CheckedContinuation<Void, any Error>] = []

    public init(
        name: String, serialNumber: String? = nil, transport: any PTPTransport, pollingInterval: Duration = .seconds(2)
    ) {
        self.name = name
        self.serialNumber = serialNumber
        self.transport = transport
        self.pollingInterval = pollingInterval
    }

    public convenience init(device: ICCameraDevice) {
        self.init(
            name: device.name ?? "Sony camera", serialNumber: device.serialNumberString,
            transport: PTPSession(device: device))
    }

    // MARK: - Connection

    /// Opens the session, runs Sony's SDIO handshake, reads every property,
    /// sets who has priority (`prefersPCPriority`), and starts keeping the
    /// properties current.  Leaves the session closed if any step fails, or
    /// if `disconnect()` is called meanwhile (then throws `CancellationError`).
    public func connect() async throws {
        stopMonitoring()
        isConnected = false
        sessionEndReason = nil
        generation += 1
        let generation = generation
        do {
            try await transport.open()
            try checkStillWanted(generation)
            let (response, _) = try await transport.exchange(PTPCommand(.sdioConnect, 1, 0, 0))
            switch response.code {
            case .ok: break
            case Self.staleSessionResponse: throw SonyCameraError.staleSession
            default: throw PTPSessionError.rejected(.sdioConnect, response.code)
            }
            try await transport.send(PTPCommand(.sdioConnect, 2, 0, 0))
            let info = try ExtendedDeviceInfo(try await fetchExtendedDeviceInfo())
            guard info.protocolVersion == Self.protocolVersion else {
                throw SonyCameraError.unsupportedProtocol(info.protocolVersion)
            }
            deviceInfo = info
            try await transport.send(PTPCommand(.sdioConnect, 3, 0, 0))
            try await refreshProperties()
            // Usually already right (the camera keeps it between sessions).
            try await applyPriority(pc: prefersPCPriority)
            try checkStillWanted(generation)
        } catch {
            if generation == self.generation { transport.close() }
            throw error
        }
        isConnected = true
        startMonitoring()
    }

    /// Whether the PC has priority over the camera's dials now.
    public var hasPCPriority: Bool { properties[.priorityKey]?.currentValue == Self.pcPriority }

    /// The mounted lens's model name, e.g. "E PZ 18-105mm F4 G OSS"; nil
    /// when the camera reports none.
    public var lensName: String? {
        if case .string(let name) = properties[.lensModelName]?.currentValue { return name }
        return nil
    }

    /// Gives the PC priority over the camera's dials, or the dials back.
    /// `remember: false` changes it only for now (e.g. handing the dials
    /// back as the app quits), not for the next connect.
    public func setPCPriority(_ isOn: Bool, remember: Bool = true) async throws {
        if remember { prefersPCPriority = isOn }
        try await applyPriority(pc: isOn)
    }

    /// Gives the PC priority, as `setPCPriority(true)` does, and waits until
    /// the camera reports it — so settings only the PC may change (the
    /// exposure mode) can follow at once.
    public func takePCPriority() async throws {
        try await setPCPriority(true)
        try await waitForProperty(.priorityKey, toBe: Self.pcPriority)
    }

    private func applyPriority(pc: Bool) async throws {
        let wanted = pc ? Self.pcPriority : Self.cameraPriority
        guard properties[.priorityKey]?.currentValue != wanted else { return }
        try await setProperty(.priorityKey, to: wanted)
    }

    public func disconnect() {
        generation += 1
        stopMonitoring()
        isConnected = false
        transport.close()
    }

    private func checkStillWanted(_ generation: Int) throws {
        guard generation == self.generation else { throw CancellationError() }
    }

    /// The raw `SDIOGetExtDeviceInfo` dataset, for diagnostics.
    public func fetchExtendedDeviceInfo() async throws -> Data {
        try await transport.send(PTPCommand(.sdioGetExtDeviceInfo, UInt32(Self.protocolVersion)))
    }

    /// The raw `GetAllExtDevicePropInfo` dataset, for diagnostics.
    public func fetchPropertyDataset() async throws -> Data {
        try await transport.send(PTPCommand(.getAllExtDevicePropInfo))
    }

    // MARK: - Properties

    /// Re-reads every property from the camera.  Calls that arrive while a
    /// read is running wait for one more read after it, which they share —
    /// so on return the properties are never older than the call.
    public func refreshProperties() async throws {
        guard !isRefreshing else {
            try await withCheckedThrowingContinuation { refreshWaiters.append($0) }
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        var waiting: [CheckedContinuation<Void, any Error>] = []
        do {
            try await readProperties()
            while !refreshWaiters.isEmpty {
                waiting = refreshWaiters
                refreshWaiters = []
                try await readProperties()
                for waiter in waiting { waiter.resume() }
                waiting = []
            }
        } catch {
            // Everyone waiting shares the failure.
            for waiter in waiting + refreshWaiters { waiter.resume(throwing: error) }
            refreshWaiters = []
            throw error
        }
    }

    private func readProperties() async throws {
        let descriptors = try PropertyDescriptor.parseAll(try await fetchPropertyDataset())
        let read = Dictionary(descriptors.map { ($0.code, $0) }, uniquingKeysWith: { _, latest in latest })
        // Only a change notifies observers: frequent reads (polling, waiting
        // for focus) mustn't redraw every view that shows a property.
        if read != properties { properties = read }
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        let events = transport.subscribeToEvents()
        let pollingInterval = pollingInterval
        monitoringTasks = [
            Task { [weak self] in
                for await event in events where event.code == .propertiesChanged {
                    // Don't wait for the read: a burst of changes (a dial being
                    // turned) folds into the reads already under way.
                    self?.requestRefresh()
                }
                // The stream ends when the camera goes away.
                guard !Task.isCancelled else { return }
                self?.sessionDidEnd(because: PTPSessionError.deviceRemoved)
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: pollingInterval)
                    guard let self else { return }
                    self.requestRefresh()
                }
            },
        ]
    }

    private func stopMonitoring() {
        for task in monitoringTasks {
            task.cancel()
        }
        monitoringTasks = []
    }

    private func requestRefresh() {
        guard isConnected else { return }
        let generation = generation
        Task {
            do {
                try await refreshProperties()
            } catch {
                // A failed read means the session is gone; a stale cache must
                // not pass for the camera's state.
                guard generation == self.generation else { return }
                sessionDidEnd(because: error)
            }
        }
    }

    private func sessionDidEnd(because reason: any Error) {
        guard isConnected else { return }
        disconnect()
        sessionEndReason = reason
    }

    /// Writes `value` in the data type the camera reports for the property.
    /// The camera applies it asynchronously; a properties-changed event follows.
    public func setProperty(_ code: SonyPropertyCode, to value: PTPValue) async throws {
        guard let descriptor = properties[code] else { throw SonyCameraError.unknownProperty(code) }
        let encoded = try value.encoded(as: descriptor.dataType)
        try await transport.send(PTPCommand(.setExtDevicePropValue, UInt32(code.rawValue)), data: encoded)
    }

    // MARK: - Controls

    public func press(_ button: SonyControlCode) async throws {
        try await perform(button, value: .unsigned(UInt64(ButtonState.down.rawValue)), as: .uint16)
    }

    public func release(_ button: SonyControlCode) async throws {
        try await perform(button, value: .unsigned(UInt64(ButtonState.up.rawValue)), as: .uint16)
    }

    /// Sends a control with a value, e.g. zoom operation with a signed speed.
    public func perform(_ control: SonyControlCode, value: PTPValue, as type: PTPDataType) async throws {
        let encoded = try value.encoded(as: type)
        try await transport.send(PTPCommand(.controlDevice, UInt32(control.rawValue)), data: encoded)
    }

    // MARK: - Live view

    /// The current live-view frame, or nil while the camera isn't ready to
    /// hand one out (it answers "invalid handle" or "access denied" then).
    public func liveViewImage() async throws -> LiveViewImage? {
        let (response, data) = try await transport.exchange(PTPCommand(.getObject, ObjectHandle.liveView.rawValue))
        switch response.code {
        case .ok: return try LiveViewImage(data)
        case .invalidObjectHandle, .accessDenied: return nil
        default: throw PTPSessionError.rejected(.getObject, response.code)
        }
    }

    // MARK: - Capturing

    /// Downloads every image waiting in camera memory — left there, e.g., by
    /// an interrupted transfer — handing each to `store` as it arrives, so
    /// none is held only in memory once it has left the camera.  Returns how
    /// many there were.
    @discardableResult
    public func drainWaitingImages(into store: (CapturedFile) async throws -> Void) async throws -> Int {
        var count = 0
        while let file = try await downloadCapturedImage() {
            try await store(file)
            count += 1
        }
        return count
    }

    /// Takes a picture and downloads its `expectedFiles` files (2 for
    /// RAW+JPEG).  Throws `CaptureError`, carrying whatever arrived, when the
    /// files don't all arrive within `timeout`, the transfer breaks off, or
    /// the files aren't one capture (different camera names, e.g. a late
    /// file of an earlier capture).
    public func capture(
        expectedFiles: Int, timeout: Duration = .seconds(30), focusTimeout: Duration = .seconds(4),
        focusPollInterval: Duration = .milliseconds(50)
    ) async throws -> [CapturedFile] {
        try await press(.shutterHalfPress)
        var isFullyPressed = false
        do {
            // In autofocus, the half press focuses first: the camera won't
            // release until it has (docs/HARDWARE_NOTES.md).
            if isAutofocusing {
                try await waitForFocus(timeout: focusTimeout, pollInterval: focusPollInterval)
            }
            try await press(.shutterFullPress)
            isFullyPressed = true
            try await Task.sleep(for: Self.shutterPressDuration)
            try await release(.shutterFullPress)
            isFullyPressed = false
        } catch {
            // Never leave the shutter pressed.
            if isFullyPressed { try? await release(.shutterFullPress) }
            try? await release(.shutterHalfPress)
            throw error
        }
        try await release(.shutterHalfPress)

        let deadline = ContinuousClock.now + timeout
        var files: [CapturedFile] = []
        do {
            while files.count < expectedFiles {
                if let file = try await downloadCapturedImage() {
                    files.append(file)
                } else if ContinuousClock.now < deadline {
                    try await Task.sleep(for: Self.capturedFilePollInterval)
                } else {
                    throw CaptureError(files: files, reason: .timedOut)
                }
            }
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError(files: files, reason: .transferFailed(String(describing: error)))
        }
        let stems = Set(files.map { ($0.info.filename as NSString).deletingPathExtension })
        guard stems.count <= 1 else { throw CaptureError(files: files, reason: .mixedCaptures) }
        return files
    }

    // MARK: - Captured images

    /// Downloads the oldest captured image waiting in camera memory, or
    /// returns nil when none is waiting.
    public func downloadCapturedImage(timeout: Duration = .seconds(60)) async throws -> CapturedFile? {
        let handle = ObjectHandle.capturedImage.rawValue
        let (response, infoData) = try await transport.exchange(PTPCommand(.getObjectInfo, handle))
        switch response.code {
        // While nothing is waiting, the A6700 answers OK with an empty dataset.
        case .ok where infoData.isEmpty, .invalidObjectHandle: return nil
        case .ok: break
        default: throw PTPSessionError.rejected(.getObjectInfo, response.code)
        }
        let info = try ObjectInfo(infoData)
        let data = try await transport.send(PTPCommand(.getObject, handle), timeout: timeout)
        return CapturedFile(info: info, data: data)
    }
}

extension SonyCamera {
    /// The focus mode autofocuses (anything but MF), so a capture must wait
    /// for focus.  Unknown (properties not read yet) counts as manual.
    public var isAutofocusing: Bool {
        guard let mode = properties[.focusMode]?.currentValue else { return false }
        return mode != .unsigned(FocusModeValue.manual)
    }

    /// Polls the camera's focus indication until it reports focus.  Throws
    /// `CaptureError.noFocus` when a single-shot mode gives up or `timeout`
    /// passes (AF-C and AF-A may keep hunting, so only the timeout ends them).
    func waitForFocus(timeout: Duration, pollInterval: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        let isSingleShot =
            properties[.focusMode]?.currentValue.bitPattern.map(FocusModeValue.singleShot.contains) == true
        // The first read comes a poll after the half press, so it reflects
        // this focusing, not the state before it.
        try await Task.sleep(for: pollInterval)
        while true {
            try await refreshProperties()
            let indication = properties[.focusIndication]?.currentValue.integerValue
            if let indication, FocusIndication.focused.contains(indication) { return }
            if isSingleShot, let indication, FocusIndication.noFocus.contains(indication) {
                throw CaptureError(files: [], reason: .noFocus)
            }
            guard ContinuousClock.now < deadline else { throw CaptureError(files: [], reason: .noFocus) }
            try await Task.sleep(for: pollInterval)
        }
    }
}

/// Values of the focus indication, `0xD213` (docs/PROPERTY_VALUES.md).
enum FocusIndication {
    /// Focused, and focused while tracking.
    static let focused: Set<Int64> = [2, 6]
    /// No focus (low contrast), and the same while tracking.
    static let noFocus: Set<Int64> = [3, 7]
}

/// Focus mode (`0x500A`) values the capture needs (the full set, with
/// names, is `CaptureCore.FocusMode`, which this module can't see).
enum FocusModeValue {
    static let manual: UInt64 = 0x0001
    /// AF-S and DMF focus once and report when they can't.
    static let singleShot: Set<UInt64> = [0x0002, 0x8006]
}

/// A capture that didn't deliver one complete set of files.
public struct CaptureError: Error, Sendable {
    public enum Reason: Equatable, Sendable {
        /// In autofocus, the camera didn't find focus; the shutter wasn't
        /// released.
        case noFocus
        /// Not all files arrived in time.
        case timedOut
        /// The transfer broke off (the description says how).
        case transferFailed(String)
        /// The files came from different captures.
        case mixedCaptures
    }

    /// The files that did arrive.
    public let files: [CapturedFile]
    public let reason: Reason
}

/// One file of a capture, as transferred from camera memory.
public struct CapturedFile: Sendable {
    /// The camera's own description: filename (as on the card) and format.
    public let info: ObjectInfo
    public let data: Data
}

public enum SonyCameraError: Error, Equatable, Sendable {
    /// The camera still holds the session of a client that quit without
    /// closing it; unplugging and replugging the cable clears it.
    case staleSession
    /// The camera didn't report this property.
    case unknownProperty(SonyPropertyCode)
    /// The camera speaks a protocol version this app doesn't.
    case unsupportedProtocol(UInt16)
    /// The camera accepted a setting but didn't apply it in time.
    case settingNotApplied(SonyPropertyCode)
    /// The camera doesn't offer this value for the property now, so it was
    /// never sent.
    case valueNotOffered(SonyPropertyCode, PTPValue)
    /// Autofocus was asked for in MF, where the camera doesn't autofocus.
    case manualFocus
    /// Not one of `SonyCamera.manualFocusSteps` (either way); never sent.
    case unsupportedFocusStep(Int16)
}
