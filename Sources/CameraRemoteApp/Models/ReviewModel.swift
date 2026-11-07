import CaptureCore
import Foundation
import ImageIO
import Observation

/// Review mode: the last capture's JPEG at full resolution in place of the
/// live view, with its clipping and sharpness, and a known length measured
/// on it for the session's scale.  A capture is decoded only
/// while review is shown, and let go when it closes — it takes a few hundred
/// megabytes.
@MainActor
@Observable
final class ReviewModel {
    enum Zoom: Equatable {
        /// The whole image in the view.
        case fit
        /// One image pixel per screen pixel.
        case actualSize
    }

    enum State {
        case empty
        case loading
        case loaded(image: CGImage, analysis: ShotAnalysis)
        /// The capture has no JPEG (RAW only) to show.
        case noJPEG
        case unreadable
    }

    var isShown = false {
        didSet {
            if !isShown { isMeasuring = false }
            refresh()
        }
    }
    /// Clicks on the image mark the ends of a known length.
    var isMeasuring = false {
        didSet { measuredEnds = [] }
    }
    /// The ends clicked so far, in image pixels from the top left.
    private(set) var measuredEnds: [CGPoint] = []
    var zoom = Zoom.fit
    /// Red over blown highlights, blue over crushed shadows.
    var showsClipping: Bool {
        didSet { UserDefaults.standard.set(showsClipping, forKey: Self.showsClippingKey) }
    }
    private(set) var state = State.empty

    /// The capture to review: the newest one.
    @ObservationIgnored var capture: LastCapture? {
        didSet {
            if capture != oldValue { refresh() }
        }
    }
    @ObservationIgnored private var loadedCapture: LastCapture?
    @ObservationIgnored private var loading: Task<Void, Never>?
    private static let showsClippingKey = "camera-remote.review.showsClipping.v1"

    init() {
        showsClipping = UserDefaults.standard.object(forKey: Self.showsClippingKey) as? Bool ?? true
    }

    var analysis: ShotAnalysis? {
        if case .loaded(_, let analysis) = state { return analysis }
        return nil
    }

    /// Adds an end of the length; a third click starts a new one.
    func markEnd(at point: CGPoint) {
        measuredEnds = measuredEnds.count < 2 ? measuredEnds + [point] : [point]
    }

    /// The pixels between the two ends, once both are marked.
    var measuredPixels: Double? {
        guard measuredEnds.count == 2 else { return nil }
        return MeasuredScale.pixels(from: measuredEnds[0], to: measuredEnds[1])
    }

    /// Loads the capture while shown, lets go of it while hidden.
    private func refresh() {
        guard isShown else {
            loading?.cancel()
            loadedCapture = nil
            state = .empty
            return
        }
        guard capture != loadedCapture else { return }
        loading?.cancel()
        loadedCapture = capture
        // Ends marked on another capture don't apply.
        measuredEnds = []
        guard let capture else {
            state = .empty
            return
        }
        guard let jpeg = capture.jpeg else {
            state = .noJPEG
            return
        }
        state = .loading
        loading = Task {
            let result = await Self.decodeAndAnalyse(jpeg)
            guard !Task.isCancelled else { return }
            state = result.map { .loaded(image: $0.image, analysis: $0.analysis) } ?? .unreadable
        }
    }

    @concurrent
    private static func decodeAndAnalyse(_ url: URL) async -> (image: CGImage, analysis: ShotAnalysis)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return (image, ShotAnalysis(image))
    }
}
