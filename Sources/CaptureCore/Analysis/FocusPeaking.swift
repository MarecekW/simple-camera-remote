import CoreGraphics
import CoreImage

/// Focus peaking: the live view's in-focus detail, marked in green on a
/// transparent image the frame's size, to lay over it.
///
/// Detail is the brightness gradient (Sobel, `CIEdges`) above a fixed
/// level: a fixed level, not a share of each frame, so a blurred frame
/// shows little or nothing instead of its least blurred parts.  The levels
/// were tuned on oak strips: at Medium, grain in focus is marked densely
/// and the same grain slightly blurred hardly at all.  Wood grain is
/// low-contrast, so in the full view mostly the strips' edges show; the
/// camera's magnifier shows the grain itself.  A 3×3 median first takes
/// out single-pixel noise (a dark scene's live view sparkles), which would
/// otherwise be marked as detail; it keeps the grain.
public struct FocusPeaking: Sendable {
    public enum Sensitivity: String, CaseIterable, Sendable {
        /// Only strong, sharp edges.
        case low
        case medium
        /// Fine, faint detail too — and more noise.
        case high

        /// The `CIEdges` output a pixel must reach to be marked.
        var threshold: Double {
            switch self {
            case .low: 0.012
            case .medium: 0.005
            case .high: 0.0025
            }
        }
    }

    public let sensitivity: Sensitivity

    /// One context for every frame: making one is costly, and it's safe to
    /// share between threads.  Each frame is new, so caching intermediate
    /// images would only churn.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    public init(sensitivity: Sensitivity) {
        self.sensitivity = sensitivity
    }

    /// The marks for `image`, on the GPU (about 1 ms for a live-view
    /// frame); nil if it couldn't be drawn.
    public func marks(for image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let edges =
            input
            // Extended past the frame, so its border isn't taken for an edge.
            .clampedToExtent()
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .applyingFilter("CIMedianFilter")
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1])
            .cropped(to: extent)
        let mask = edges.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": sensitivity.threshold])
        let marks = CIImage(color: Self.colour).cropped(to: extent)
            .applyingFilter(
                "CIBlendWithMask",
                parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
        return Self.context.createCGImage(marks, from: extent)
    }

    /// A light green that stands out on wood, black and grey alike.
    private static let colour = CIColor(red: 0.2, green: 1, blue: 0.2)

    /// The share of `marks`' pixels that are marked, for tests and checks.
    public static func markedShare(of marks: CGImage) -> Double {
        let width = marks.width
        let height = marks.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let bitmap = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        bitmap.draw(marks, in: CGRect(x: 0, y: 0, width: width, height: height))
        let marked = stride(from: 3, to: pixels.count, by: 4).count { pixels[$0] > 127 }
        return Double(marked) / Double(width * height)
    }
}
