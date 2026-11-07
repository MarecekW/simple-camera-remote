import Foundation
import SonyProtocol

/// A PTP session with a camera: what `SonyCamera` needs from the transport.
///
/// `PTPSession` implements it over ImageCaptureCore; tests implement it with
/// recorded responses.
@MainActor
public protocol PTPTransport: AnyObject {
    /// A new stream of the camera's PTP events, in arrival order, from now
    /// until the camera goes away.  Every subscriber gets every event.
    func subscribeToEvents() -> AsyncStream<PTPEvent>

    func open() async throws
    func close()

    /// Sends `command`, with `data` for the host-to-camera data phase, and
    /// returns the response whatever its code, with the camera's data.
    func exchange(_ command: PTPCommand, data: Data?, timeout: Duration) async throws -> (PTPResponse, Data)
}

extension PTPTransport {
    /// Like `exchange`, but throws unless the camera answers OK, and returns
    /// only the data.
    @discardableResult
    public func send(_ command: PTPCommand, data: Data? = nil, timeout: Duration = .seconds(10)) async throws -> Data {
        let (response, received) = try await exchange(command, data: data, timeout: timeout)
        guard response.code == .ok else { throw PTPSessionError.rejected(command.operation, response.code) }
        return received
    }

    public func exchange(_ command: PTPCommand, data: Data? = nil) async throws -> (PTPResponse, Data) {
        try await exchange(command, data: data, timeout: .seconds(10))
    }
}

/// Why a PTP exchange failed.
public enum PTPSessionError: Error, Equatable, Sendable {
    case sessionNotOpen
    case openFailed(code: Int)
    /// The camera didn't answer in time.  ImageCaptureCore can't cancel a
    /// request, so the session is closed and must be reopened.
    case timedOut(PTPOperationCode)
    /// ImageCaptureCore reported an error (domain `com.apple.ImageCaptureCore`).
    case transportFailed(code: Int)
    /// The camera answered with something other than OK.
    case rejected(PTPOperationCode, PTPResponseCode)
    case malformedResponse(ProtocolError)
    case deviceRemoved
}
