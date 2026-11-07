import Accelerate
import CoreGraphics
import Foundation

/// What review mode tells about a capture: its histogram, how much of it is
/// clipped (with a map of where), and how sharp it is.
public struct ShotAnalysis: Sendable {
    public let histogram: Histogram?
    /// Share of pixels with a channel at full brightness.
    public let highlightClipping: Double
    /// Share of pixels black in every channel.
    public let shadowClipping: Double
    /// Clipped highlights red and clipped shadows blue, transparent
    /// elsewhere, at most `maskSize` across; nil when nothing is clipped.
    public let clippingMask: CGImage?
    /// The variance of the image's Laplacian over its centre: higher is
    /// sharper.  Comparable between shots of the same subject and setup, not
    /// across different subjects.
    public let sharpness: Double?

    /// Analyses `image` at full resolution — slow for a capture, so run it
    /// off the main thread.
    public init(_ image: CGImage) {
        let pixels = Pixels(image)
        histogram = pixels?.histogram
        highlightClipping = pixels?.highlightClipping ?? 0
        shadowClipping = pixels?.shadowClipping ?? 0
        clippingMask = pixels?.clippingMask
        sharpness = Self.sharpness(of: image)
    }

    // MARK: - Histogram and clipping

    /// The clipping mask's longest side.  Each mask pixel covers a block of
    /// the image and is marked if any pixel in it is clipped, so a small
    /// blown highlight still shows.
    static let maskSize = 2048

    /// One pass over the image's pixels for the histogram and the clipping.
    private struct Pixels {
        let histogram: Histogram
        let highlightClipping: Double
        let shadowClipping: Double
        let clippingMask: CGImage?

        init?(_ image: CGImage) {
            let width = image.width
            let height = image.height
            guard width > 0, height > 0, let rgba = ShotAnalysis.rgbaPixels(of: image) else { return nil }
            let block = max(1, Int((Double(max(width, height)) / Double(maskSize)).rounded(.up)))
            let maskWidth = (width + block - 1) / block
            let maskHeight = (height + block - 1) / block
            // Per mask pixel: 2 for highlights (they win), 1 for shadows.
            var marks = [UInt8](repeating: 0, count: maskWidth * maskHeight)
            var red = [Int](repeating: 0, count: 256)
            var green = [Int](repeating: 0, count: 256)
            var blue = [Int](repeating: 0, count: 256)
            var highlights = 0
            var shadows = 0
            rgba.withUnsafeBufferPointer { bytes in
                for y in 0..<height {
                    let maskRow = (y / block) * maskWidth
                    for x in 0..<width {
                        let offset = (y * width + x) * 4
                        let r = bytes[offset]
                        let g = bytes[offset + 1]
                        let b = bytes[offset + 2]
                        red[Int(r)] += 1
                        green[Int(g)] += 1
                        blue[Int(b)] += 1
                        let mark = maskRow + x / block
                        if r == 255 || g == 255 || b == 255 {
                            highlights += 1
                            marks[mark] = 2
                        } else if r == 0 && g == 0 && b == 0 {
                            shadows += 1
                            if marks[mark] == 0 { marks[mark] = 1 }
                        }
                    }
                }
            }
            let count = Double(width * height)
            histogram = Histogram(red: red, green: green, blue: blue)
            highlightClipping = Double(highlights) / count
            shadowClipping = Double(shadows) / count
            clippingMask =
                highlights + shadows > 0 ? ShotAnalysis.maskImage(marks, width: maskWidth, height: maskHeight) : nil
        }
    }

    /// `image` as 8-bit RGBA (alpha last) in its own RGB colour space, or
    /// sRGB for anything else.
    private static func rgbaPixels(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        let space =
            image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// Opaque red where `marks` is 2, opaque blue where 1, clear elsewhere.
    private static func maskImage(_ marks: [UInt8], width: Int, height: Int) -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for (index, mark) in marks.enumerated() where mark > 0 {
            rgba[index * 4 + (mark == 2 ? 0 : 2)] = 255
            rgba[index * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Sharpness

    /// The largest central square measured for sharpness: enough detail to
    /// judge focus without processing all 25 megapixels.
    static let sharpnessRegion = 2048

    private static func sharpness(of image: CGImage) -> Double? {
        let side = min(sharpnessRegion, image.width, image.height)
        let crop = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        guard side >= 3, let centre = image.cropping(to: crop), let gray = grayPixels(of: centre, side: side)
        else { return nil }

        var source = gray.map(Float.init)
        var laplacian = [Float](repeating: 0, count: side * side)
        let kernel: [Float] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
        let error = source.withUnsafeMutableBufferPointer { sourcePointer in
            laplacian.withUnsafeMutableBufferPointer { destinationPointer in
                var input = vImage_Buffer(
                    data: sourcePointer.baseAddress, height: vImagePixelCount(side), width: vImagePixelCount(side),
                    rowBytes: side * MemoryLayout<Float>.size)
                var output = vImage_Buffer(
                    data: destinationPointer.baseAddress, height: vImagePixelCount(side),
                    width: vImagePixelCount(side), rowBytes: side * MemoryLayout<Float>.size)
                return vImageConvolve_PlanarF(
                    &input, &output, nil, 0, 0, kernel, 3, 3, 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        guard error == kvImageNoError else { return nil }
        var mean: Float = 0
        var deviation: Float = 0
        vDSP_normalize(laplacian, 1, nil, 1, &mean, &deviation, vDSP_Length(laplacian.count))
        return Double(deviation * deviation)
    }

    /// `image` as 8-bit grey, `side` × `side`.
    private static func grayPixels(of image: CGImage, side: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? pixels : nil
    }
}
