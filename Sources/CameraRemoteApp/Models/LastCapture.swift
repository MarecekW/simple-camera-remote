import Foundation

/// The newest capture, as shown in the inspector's footer.
struct LastCapture: Equatable {
    let name: String
    /// Its number in the session.
    let sequence: Int
    /// The stored files (RAW and JPEG).
    let files: [URL]
    /// All its files together.
    let bytes: Int
    let capturedAt: Date
    /// The focal length it was taken at, in thousandths of a millimetre;
    /// nil when unknown.
    let focalLength: UInt32?

    /// For the thumbnail, review and as an overlay.
    var jpeg: URL? {
        files.first { $0.pathExtension.caseInsensitiveCompare("JPG") == .orderedSame }
    }
}
