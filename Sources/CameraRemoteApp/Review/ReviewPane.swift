import AppKit
import CaptureCore
import SwiftUI

/// The reviewed capture, zoomable: fit or 100 % from the toolbar, pinch and
/// scroll to look around, double-click to switch between fit and 100 % at
/// that spot.  The clipping map lies over it when shown; while measuring,
/// clicks mark the ends of a length, joined by a line.
struct ReviewPane: View {
    @Bindable var review: ReviewModel

    private func message(_ text: String) -> some View {
        Text(text).foregroundStyle(Theme.textSecondary)
    }

    var body: some View {
        ZStack {
            Theme.background
            switch review.state {
            case .loaded(let image, let analysis):
                ZoomableImage(
                    image: image, mask: review.showsClipping ? analysis.clippingMask : nil, zoom: $review.zoom,
                    measuredEnds: review.measuredEnds, markEnd: review.isMeasuring ? { review.markEnd(at: $0) } : nil)
            case .loading:
                ProgressView("Loading the capture…")
            case .empty:
                message("No capture to review yet.")
            case .noJPEG:
                message("Review needs a JPEG: set Format to RAW+JPEG.")
            case .unreadable:
                message("The last capture's JPEG couldn't be read.")
            }
        }
    }
}

/// An image in a magnifying scroll view.  Its size in points is its size in
/// pixels, so 100 % is a magnification of 1 / the screen's scale.
private struct ZoomableImage: NSViewRepresentable {
    let image: CGImage
    let mask: CGImage?
    @Binding var zoom: ReviewModel.Zoom
    let measuredEnds: [CGPoint]
    /// Takes clicks while measuring; nil otherwise.
    let markEnd: ((CGPoint) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.contentView = CentringClipView()
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 4
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = context.coordinator.document
        scrollView.postsFrameChangedNotifications = true
        context.coordinator.observeResizing(of: scrollView)
        let coordinator = context.coordinator
        coordinator.doubleClick.numberOfClicksRequired = 2
        coordinator.document.addGestureRecognizer(coordinator.doubleClick)
        coordinator.document.addGestureRecognizer(coordinator.click)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.zoom = $zoom
        coordinator.markEnd = markEnd
        // While measuring a click marks a point, so it can't wait to see
        // whether it becomes a double-click; Z still zooms.
        coordinator.click.isEnabled = markEnd != nil
        coordinator.doubleClick.isEnabled = markEnd == nil
        coordinator.document.show(image, mask: mask)
        coordinator.document.showMeasurement(between: measuredEnds)
        if coordinator.appliedZoom != zoom || coordinator.appliedImage !== image {
            coordinator.appliedZoom = zoom
            coordinator.appliedImage = image
            coordinator.apply(zoom, in: scrollView, around: nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        let document = ImageDocumentView()
        private(set) lazy var click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
        private(set) lazy var doubleClick = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked(_:)))
        var zoom: Binding<ReviewModel.Zoom>?
        var markEnd: ((CGPoint) -> Void)?
        var appliedZoom: ReviewModel.Zoom?
        var appliedImage: CGImage?
        private var resizeObserver: NSObjectProtocol?

        func stopObserving() {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            resizeObserver = nil
        }

        func observeResizing(of scrollView: NSScrollView) {
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main
            ) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let self, let scrollView, self.appliedZoom == .fit else { return }
                    self.apply(.fit, in: scrollView, around: nil)
                }
            }
        }

        /// Fits the image, or shows it at 100 % with `point` (in the image's
        /// coordinates) kept where it is, or around the middle of what's
        /// shown.
        func apply(_ zoom: ReviewModel.Zoom, in scrollView: NSScrollView, around point: NSPoint?) {
            let size = document.frame.size
            guard size.width > 0, size.height > 0 else { return }
            switch zoom {
            case .fit:
                let visible = scrollView.frame.size
                scrollView.magnification = min(visible.width / size.width, visible.height / size.height)
            case .actualSize:
                let scale = scrollView.window?.backingScaleFactor ?? 2
                let centre =
                    point ?? NSPoint(x: scrollView.documentVisibleRect.midX, y: scrollView.documentVisibleRect.midY)
                scrollView.setMagnification(1 / scale, centeredAt: centre)
            }
        }

        /// The document's coordinates are the image's pixels, top left first.
        @objc func clicked(_ recognizer: NSClickGestureRecognizer) {
            markEnd?(recognizer.location(in: document))
        }

        @objc func doubleClicked(_ recognizer: NSClickGestureRecognizer) {
            guard let scrollView = document.enclosingScrollView, let zoom else { return }
            let next: ReviewModel.Zoom = appliedZoom == .actualSize ? .fit : .actualSize
            appliedZoom = next
            apply(next, in: scrollView, around: recognizer.location(in: document))
            zoom.wrappedValue = next
        }
    }
}

/// The image, its clipping map and a measured length, as layers.
final class ImageDocumentView: NSView {
    private let imageLayer = CALayer()
    private let maskLayer = CALayer()
    private let measureLayer = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // A capture is shown at about an eighth of its size to fit: mipmaps
        // keep fine detail (wood grain) from aliasing.
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
        maskLayer.opacity = 0.75
        // Keep the mask's pixels crisp when magnified.
        maskLayer.magnificationFilter = .nearest
        layer?.addSublayer(maskLayer)
        measureLayer.fillColor = nil
        measureLayer.strokeColor = NSColor(Theme.guide).cgColor
        layer?.addSublayer(measureLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    override var isFlipped: Bool { true }

    func show(_ image: CGImage, mask: CGImage?) {
        let size = NSSize(width: image.width, height: image.height)
        if frame.size != size { setFrameSize(size) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        imageLayer.frame = bounds
        maskLayer.contents = mask
        maskLayer.frame = bounds
        measureLayer.frame = bounds
        CATransaction.commit()
    }

    /// A ring at each end and a line between them.  Sized to the image, not
    /// the screen: thin at 100 %, still visible fitted.
    func showMeasurement(between ends: [CGPoint]) {
        let lineWidth = max(frame.width, frame.height) / 1000
        let radius = 4 * lineWidth
        let path = CGMutablePath()
        for end in ends {
            path.addEllipse(in: CGRect(x: end.x - radius, y: end.y - radius, width: 2 * radius, height: 2 * radius))
        }
        if ends.count == 2 {
            path.move(to: ends[0])
            path.addLine(to: ends[1])
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        measureLayer.lineWidth = lineWidth
        measureLayer.path = path
        CATransaction.commit()
    }
}

/// Keeps a document smaller than the view in its middle, instead of the
/// bottom-left corner.
private final class CentringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return bounds }
        if bounds.width > document.frame.width { bounds.origin.x = (document.frame.width - bounds.width) / 2 }
        if bounds.height > document.frame.height { bounds.origin.y = (document.frame.height - bounds.height) / 2 }
        return bounds
    }
}
