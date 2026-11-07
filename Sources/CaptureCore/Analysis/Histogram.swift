import Accelerate
import CoreGraphics

/// Red, green and blue histograms of an image, 256 bins each — what the
/// camera's own histogram shows, and what reveals clipping.
public struct Histogram: Equatable, Sendable {
    public let red: [Int]
    public let green: [Int]
    public let blue: [Int]

    /// From counted bins (256 per channel).
    init(red: [Int], green: [Int], blue: [Int]) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Nil when the image can't be read as 8-bit RGB.
    public init?(image: CGImage) {
        guard
            let format = vImage_CGImageFormat(
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                // The image's own colour space, so its values are counted as
                // they are, without conversion.
                colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
            ),
            var buffer = try? vImage_Buffer(cgImage: image, format: format)
        else { return nil }
        defer { buffer.free() }

        // One 256-bin block per channel of the RGBX buffer, side by side.
        var bins = [vImagePixelCount](repeating: 0, count: 4 * 256)
        let error = bins.withUnsafeMutableBufferPointer { storage in
            guard let base = storage.baseAddress else { return kvImageMemoryAllocationError }
            var channels: [UnsafeMutablePointer<vImagePixelCount>?] = (0..<4).map { base + $0 * 256 }
            return vImageHistogramCalculation_ARGB8888(&buffer, &channels, vImage_Flags(kvImageNoFlags))
        }
        guard error == kvImageNoError else { return nil }
        func channel(_ index: Int) -> [Int] {
            bins[(index * 256)..<((index + 1) * 256)].map { Int($0) }
        }
        red = channel(0)
        green = channel(1)
        blue = channel(2)
    }

    /// Share of channel samples at full brightness (255): 1 when every
    /// channel of every pixel is blown, 1/3 when only one channel is.
    public var clippedSampleFraction: Double {
        let total = red.reduce(0, +) + green.reduce(0, +) + blue.reduce(0, +)
        guard total > 0 else { return 0 }
        return Double(red[255] + green[255] + blue[255]) / Double(total)
    }
}
