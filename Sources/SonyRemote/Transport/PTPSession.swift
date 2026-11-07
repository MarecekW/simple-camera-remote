import Foundation
import ImageCaptureCore
import SonyProtocol

/// A PTP session with one camera, through the system's PTP service.
///
/// Exactly one request is in flight at a time (PTP allows no more per
/// session); later requests wait their turn in order.  A request holds the
/// turn until ImageCaptureCore actually completes it — ImageCaptureCore has
/// no timeouts and can't cancel, so a request that misses its deadline fails
/// its caller, closes the session (the stuck request still holds the camera)
/// and keeps the turn until it finally completes.
///
/// Everything runs on the main actor; requests only enqueue work there, so
/// nothing blocks it.
@MainActor
public final class PTPSession: NSObject, PTPTransport {
    /// How long the system gets to open the session before `open()` gives
    /// up — it normally takes well under a second.
    private static let openTimeout: Duration = .seconds(10)

    private enum State {
        case closed
        case opening(CheckedContinuation<Void, any Error>, deadline: Task<Void, Never>)
        case open
    }

    private struct PendingReply {
        let continuation: CheckedContinuation<(PTPResponse, Data), any Error>
        let deadline: Task<Void, Never>
    }

    public let device: ICCameraDevice
    /// Events as ImageCaptureCore delivers them (on any thread); one task on
    /// the main actor reads them and fans them out to the subscribers.
    private let incomingEvents: AsyncStream<PTPEvent>.Continuation
    private var subscribers: [UUID: AsyncStream<PTPEvent>.Continuation] = [:]
    private var deviceIsGone = false

    private var state = State.closed
    /// Bumped on every open, so a deadline from an earlier open can't fail a
    /// later one.
    private var generation = 0
    /// Close confirmations still to come for closes we asked for; any other
    /// close comes from the system or the camera.
    private var requestedCloses = 0
    private var isTurnTaken = false
    /// Waiting requests; resumed with `true` when given the turn, `false`
    /// when the session ended first.
    private var queuedRequests: [CheckedContinuation<Bool, Never>] = []
    private var pendingReplies: [UUID: PendingReply] = [:]

    public init(device: ICCameraDevice) {
        self.device = device
        let (incoming, continuation) = AsyncStream.makeStream(of: PTPEvent.self)
        incomingEvents = continuation
        super.init()
        device.delegate = self
        Task { [weak self] in
            for await event in incoming {
                self?.publish(event)
            }
            self?.finishSubscribers()
        }
    }

    public func subscribeToEvents() -> AsyncStream<PTPEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: PTPEvent.self)
        guard !deviceIsGone else {
            continuation.finish()
            return stream
        }
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[id] = nil }
        }
        return stream
    }

    private func publish(_ event: PTPEvent) {
        for subscriber in subscribers.values {
            subscriber.yield(event)
        }
    }

    private func finishSubscribers() {
        deviceIsGone = true
        for subscriber in subscribers.values {
            subscriber.finish()
        }
        subscribers = [:]
    }

    private var isOpen: Bool {
        if case .open = state { return true }
        return false
    }

    // MARK: - Session

    public func open() async throws {
        guard case .closed = state else { return }
        generation += 1
        let generation = generation
        try await withCheckedThrowingContinuation { continuation in
            let deadline = Task {
                try? await Task.sleep(for: Self.openTimeout)
                guard !Task.isCancelled, generation == self.generation else { return }
                self.finishOpen(throwing: PTPSessionError.timedOut(.openSession))
            }
            state = .opening(continuation, deadline: deadline)
            device.requestOpenSession()
        }
    }

    public func close() {
        guard isOpen else { return }
        endSession(with: .sessionNotOpen)
    }

    private func finishOpen(throwing error: (any Error)?) {
        guard case .opening(let continuation, let deadline) = state else { return }
        deadline.cancel()
        if let error {
            state = .closed
            continuation.resume(throwing: error)
        } else {
            state = .open
            continuation.resume()
        }
    }

    /// Fails everything in flight and waiting, then asks the system to close.
    private func endSession(with error: PTPSessionError) {
        failAll(with: error)
        requestedCloses += 1
        device.requestCloseSession()
    }

    private func failAll(with error: PTPSessionError) {
        finishOpen(throwing: error)
        state = .closed
        for id in pendingReplies.keys {
            reply(id, with: .failure(error))
        }
        let waiting = queuedRequests
        queuedRequests.removeAll()
        for request in waiting {
            request.resume(returning: false)
        }
    }

    // MARK: - Requests

    public func exchange(_ command: PTPCommand, data: Data?, timeout: Duration) async throws -> (PTPResponse, Data) {
        guard isOpen, await waitForTurn() else { throw PTPSessionError.sessionNotOpen }
        // The session may have ended while the request waited.
        guard isOpen else {
            releaseTurn()
            throw PTPSessionError.sessionNotOpen
        }

        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            let deadline = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self.timeOut(id, operation: command.operation)
            }
            pendingReplies[id] = PendingReply(continuation: continuation, deadline: deadline)
            device.requestSendPTPCommand(command.encoded, outData: data) { first, second, error in
                // Runs on an arbitrary queue.
                let result = Self.decode(first, second, error)
                Task { @MainActor in
                    self.reply(id, with: result)
                    // The camera has answered, so the next request may go —
                    // even if this one's caller already gave up on it.
                    self.releaseTurn()
                }
            }
        }
    }

    /// The completion's two buffers are the data phase and the response
    /// container; their order isn't documented, so the response is found by
    /// its container type.  The data is copied before it leaves the callback.
    nonisolated private static func decode(_ first: Data, _ second: Data, _ error: (any Error)?)
        -> Result<(PTPResponse, Data), any Error>
    {
        if let error { return .failure(PTPSessionError.transportFailed(code: (error as NSError).code)) }
        do throws(ProtocolError) {
            return .success((try PTPResponse(container: second), Data(copying: first)))
        } catch {
            guard let response = try? PTPResponse(container: first) else {
                return .failure(PTPSessionError.malformedResponse(error))
            }
            return .success((response, Data(copying: second)))
        }
    }

    private func reply(_ id: UUID, with result: Result<(PTPResponse, Data), any Error>) {
        guard let pending = pendingReplies.removeValue(forKey: id) else { return }
        pending.deadline.cancel()
        pending.continuation.resume(with: result)
    }

    private func timeOut(_ id: UUID, operation: PTPOperationCode) {
        guard pendingReplies[id] != nil else { return }
        reply(id, with: .failure(PTPSessionError.timedOut(operation)))
        if isOpen { endSession(with: .timedOut(operation)) }
    }

    /// Waits for the turn; false if the session ended while waiting.
    private func waitForTurn() async -> Bool {
        guard isTurnTaken else {
            isTurnTaken = true
            return true
        }
        return await withCheckedContinuation { queuedRequests.append($0) }
    }

    private func releaseTurn() {
        if queuedRequests.isEmpty {
            isTurnTaken = false
        } else {
            // The turn passes straight to the next waiter.
            queuedRequests.removeFirst().resume(returning: true)
        }
    }

    // MARK: - Delegate events, on the main actor

    private func sessionDidClose() {
        // Our own closes were already handled when we asked for them.
        if requestedCloses > 0 {
            requestedCloses -= 1
        } else {
            failAll(with: .sessionNotOpen)
        }
    }
}

extension Data {
    /// A copy that owns its bytes, independent of the buffer it came from.
    fileprivate init(copying data: Data) {
        self = data.withUnsafeBytes { Data($0) }
    }
}

// MARK: - ImageCaptureCore delegate

// The callbacks are `nonisolated`: the headers promise the main thread, but
// PTP events arrive on a background thread (seen on macOS 27), so each
// callback hops to the main actor itself — or, for events, yields into the
// incoming stream, which is safe from any thread.
extension PTPSession: ICCameraDeviceDelegate {
    nonisolated public func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        let failure = error.map { PTPSessionError.openFailed(code: ($0 as NSError).code) }
        Task { @MainActor in self.finishOpen(throwing: failure) }
    }

    nonisolated public func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        Task { @MainActor in self.sessionDidClose() }
    }

    nonisolated public func didRemove(_ device: ICDevice) {
        Task { @MainActor in self.failAll(with: .deviceRemoved) }
        incomingEvents.finish()
    }

    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        // Malformed events can't be acted on; dropping them is all we can do.
        guard let event = try? PTPEvent(container: eventData) else { return }
        incomingEvents.yield(event)
    }

    // The camera's storage isn't browsed through ImageCaptureCore — captures
    // arrive over PTP — so the catalogue callbacks are no-ops, and thumbnails
    // and metadata are declined to keep ImageCaptureCore from fetching them.
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, shouldGetThumbnailOf item: ICCameraItem) -> Bool {
        false
    }
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, shouldGetMetadataOf item: ICCameraItem) -> Bool {
        false
    }
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated public func cameraDevice(
        _ camera: ICCameraDevice,
        didReceiveThumbnail thumbnail: CGImage?,
        for item: ICCameraItem,
        error: (any Error)?
    ) {}
    nonisolated public func cameraDevice(
        _ camera: ICCameraDevice,
        didReceiveMetadata metadata: [AnyHashable: Any]?,
        for item: ICCameraItem,
        error: (any Error)?
    ) {}
    nonisolated public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    nonisolated public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}
