import OSLog

/// The app's log categories; view them in Console.app by subsystem.
enum Log {
    private static let subsystem = "dev.marekkramar.SimpleCameraRemote"

    /// Connecting, the camera session, protocol errors.
    static let ptp = Logger(subsystem: subsystem, category: "ptp")
    /// Live-view frames and the reference overlay.
    static let liveView = Logger(subsystem: subsystem, category: "liveView")
    /// Storing captures and their records.
    static let capture = Logger(subsystem: subsystem, category: "capture")
}
