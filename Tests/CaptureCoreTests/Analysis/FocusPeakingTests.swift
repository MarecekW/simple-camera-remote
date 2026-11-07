import CaptureCore
import CoreGraphics
import Foundation
import Testing

struct FocusPeakingTests {
    /// A grey image whose brightness at column x is `level(x)`.
    private func image(width: Int = 128, height: Int = 64, _ level: (Int) -> UInt8) throws -> CGImage {
        var pixels = [UInt8]()
        for _ in 0..<height {
            for x in 0..<width {
                let value = level(x)
                pixels += [value, value, value, 255]
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func markedShare(_ image: CGImage, _ sensitivity: FocusPeaking.Sensitivity = .medium) throws -> Double {
        let marks = try #require(FocusPeaking(sensitivity: sensitivity).marks(for: image))
        #expect(marks.width == image.width && marks.height == image.height)
        return FocusPeaking.markedShare(of: marks)
    }

    @Test func marksNothingOnAFlatImage() throws {
        // Including its border: the frame's edge isn't detail.
        #expect(try markedShare(image { _ in 128 }, .high) == 0)
    }

    @Test func marksFineDetailButNotTheSameDetailBlurred() throws {
        // Low-contrast stripes 2 px wide, as grain in focus; the same
        // contrast spread over 32 px, as it is out of focus.
        let sharp = try markedShare(image { x in x / 2 % 2 == 0 ? 110 : 150 })
        let blurred = try markedShare(image { x in UInt8(130 + 20 * sin(Double(x) * .pi / 32)) })
        #expect(sharp > 0.3)
        #expect(blurred == 0)
    }

    @Test func higherSensitivityMarksFainterDetail() throws {
        let faint = try image { x in x / 2 % 2 == 0 ? 124 : 136 }
        #expect(try markedShare(faint, .low) < markedShare(faint, .high))
    }
}
