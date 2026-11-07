import CaptureCore
import CoreGraphics
import Foundation
import Testing

struct ShotAnalysisTests {
    /// An sRGB image whose pixel at (x, y) is `colour(x, y)` (r, g, b).
    private func image(width: Int, height: Int, _ colour: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        var pixels = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let (red, green, blue) = colour(x, y)
                pixels += [red, green, blue, 255]
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @Test func countsBlownAndCrushedPixels() throws {
        // Left quarter white, next quarter black, the rest mid grey.
        let shot = ShotAnalysis(
            try image(width: 64, height: 16) { x, _ in
                x < 16 ? (255, 255, 255) : x < 32 ? (0, 0, 0) : (128, 128, 128)
            })
        #expect(abs(shot.highlightClipping - 0.25) < 0.01)
        #expect(abs(shot.shadowClipping - 0.25) < 0.01)
        #expect(shot.clippingMask != nil)
    }

    @Test func aWellExposedShotHasNoMask() throws {
        let shot = ShotAnalysis(try image(width: 32, height: 32) { x, y in (UInt8(60 + x), UInt8(60 + y), 100) })
        #expect(shot.highlightClipping == 0)
        #expect(shot.shadowClipping == 0)
        #expect(shot.clippingMask == nil)
    }

    @Test func aSharpPatternScoresHigherThanABlurredOne() throws {
        let sharp = try image(width: 64, height: 64) { x, y in
            (x / 4 + y / 4).isMultiple(of: 2) ? (230, 230, 230) : (30, 30, 30)
        }
        // The same squares with soft edges.
        let soft = try image(width: 64, height: 64) { x, y in
            let level = UInt8(130 + 50 * sin(Double(x) * .pi / 4) * sin(Double(y) * .pi / 4))
            return (level, level, level)
        }
        let sharpScore = try #require(ShotAnalysis(sharp).sharpness)
        let softScore = try #require(ShotAnalysis(soft).sharpness)
        #expect(sharpScore > softScore * 4)
    }

    @Test func paintsTheMaskRedAndBlue() throws {
        let shot = ShotAnalysis(try image(width: 2, height: 1) { x, _ in x == 0 ? (255, 10, 10) : (0, 0, 0) })
        let mask = try #require(shot.clippingMask)
        let data = try #require(mask.dataProvider?.data as Data?)
        #expect(Array(data.prefix(8)) == [255, 0, 0, 255, 0, 0, 255, 255])
    }

    @Test func aSmallBlownSpotShowsInALargeImage() throws {
        // 4200 px wide: each mask pixel covers 3 image pixels; one blown pixel.
        let shot = ShotAnalysis(
            try image(width: 4200, height: 6) { x, y in x == 2101 && y == 3 ? (255, 255, 255) : (90, 90, 90) })
        let mask = try #require(shot.clippingMask)
        #expect(mask.width == 1400)
        #expect(shot.highlightClipping == 1.0 / (4200 * 6))
    }

    @Test func measuresSharpnessOnAWideImage() throws {
        let wide = try image(width: 2100, height: 40) { x, _ in
            (x / 3).isMultiple(of: 2) ? (220, 220, 220) : (40, 40, 40)
        }
        #expect(try #require(ShotAnalysis(wide).sharpness) > 0)
    }
}
