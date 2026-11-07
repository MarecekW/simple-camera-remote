import CoreGraphics
import Foundation
import Testing

@testable import CaptureCore

struct HistogramTests {
    @Test func countsEveryPixelOfASolidColour() throws {
        let image = try #require(solidImage(width: 4, height: 2, red: 255, green: 128, blue: 0))
        let histogram = try #require(Histogram(image: image))
        #expect(histogram.red[255] == 8)
        #expect(histogram.green[128] == 8)
        #expect(histogram.blue[0] == 8)
        #expect(histogram.red.reduce(0, +) == 8)
    }

    @Test func reportsClippedSamples() throws {
        let clippedImage = try #require(solidImage(width: 2, height: 2, red: 255, green: 10, blue: 10))
        let cleanImage = try #require(solidImage(width: 2, height: 2, red: 200, green: 10, blue: 10))
        let clipped = try #require(Histogram(image: clippedImage))
        let clean = try #require(Histogram(image: cleanImage))
        #expect(clipped.clippedSampleFraction == 1.0 / 3)  // only red is blown
        #expect(clean.clippedSampleFraction == 0)
    }

    private func solidImage(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> CGImage? {
        let pixels = [UInt8]((0..<(width * height)).flatMap { _ in [red, green, blue, 255] })
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
