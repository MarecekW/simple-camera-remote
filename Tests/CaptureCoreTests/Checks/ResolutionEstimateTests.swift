import CaptureCore
import Testing

struct ResolutionEstimateTests {
    @Test func unitMagnificationAtFourFocalLengths() throws {
        // At D = 4f the subject is imaged life size: 6192 px over 23.3 mm.
        let estimate = try #require(ResolutionEstimate(focalLength: 50, distance: 200))
        #expect(abs(estimate.magnification - 1) < 1e-9)
        #expect(abs(estimate.pixelsPerMillimetre - 6192 / 23.3) < 1e-6)
    }

    @Test func aTypicalRigDistance() throws {
        // 35 mm from 450 mm: u = (450 + √139500) / 2 = 411.75, v = 38.25,
        // m = 0.0929.
        let estimate = try #require(ResolutionEstimate(focalLength: 35, distance: 450))
        #expect(abs(estimate.magnification - 0.0929) < 0.0001)
        #expect(abs(estimate.pixelsPerMillimetre - 24.69) < 0.02)
        #expect(abs(estimate.fieldOfView.width - 250.8) < 0.2)
        // A 2 mm knot: ~49 px.
        #expect(abs(estimate.pixels(forFeature: 2) - 49.4) < 0.1)
    }

    @Test func aSmallerImageHasFewerPixelsPerMillimetre() throws {
        let large = try #require(ResolutionEstimate(focalLength: 35, distance: 450))
        let small = try #require(ResolutionEstimate(focalLength: 35, distance: 450, sizeScale: 0.5))
        #expect(abs(small.pixelsPerMillimetre - large.pixelsPerMillimetre / 2) < 1e-9)
    }

    @Test func theMaximumDistanceGivesBackTheRequiredScale() throws {
        let distance = try #require(ResolutionEstimate.maximumDistance(focalLength: 50, pixelsPerMillimetre: 30))
        let estimate = try #require(ResolutionEstimate(focalLength: 50, distance: distance))
        #expect(abs(estimate.pixelsPerMillimetre - 30) < 1e-6)
    }

    @Test(arguments: [0.0, -5, .infinity])
    func hasNoDistanceForAnImpossibleScale(pixelsPerMillimetre: Double) {
        #expect(ResolutionEstimate.maximumDistance(focalLength: 35, pixelsPerMillimetre: pixelsPerMillimetre) == nil)
    }

    @Test func scalesTheImageSizes() {
        #expect(ResolutionEstimate.sizeScale(of: .large) == 1)
        #expect(abs(ResolutionEstimate.sizeScale(of: .medium) - 0.708) < 0.001)
        #expect(abs(ResolutionEstimate.sizeScale(of: .small) - 0.501) < 0.001)
    }

    @Test func refusesASubjectTooCloseToFocus() {
        #expect(ResolutionEstimate(focalLength: 50, distance: 150) == nil)
    }
}
