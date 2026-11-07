import AppKit
import CaptureCore
import SonyProtocol
import SonyRemote
import SwiftUI

/// The live view with its overlays, all drawn in the image's own rectangle so
/// grid, crosshair and reference image line up with the picture, whatever
/// the window's shape.
///
/// Only the leaf view `LiveFrame` reads per-frame data, so a new frame
/// doesn't re-render the pane's layout.
struct LiveViewPane: View {
    let liveView: LiveViewModel
    /// A click: where on the image (0…1), or nil outside it.
    let onClick: (LiveViewPoint?) -> Void

    /// The live view's shape before the first frame: 1024×680 (3:2).
    private static let defaultAspectRatio = 1024.0 / 680.0

    var body: some View {
        GeometryReader { geometry in
            // Rulers take a strip along the top and left; the image fits in
            // the rest.
            let inset = liveView.showsRulers ? Rulers.thickness : 0
            let available = CGSize(width: geometry.size.width - inset, height: geometry.size.height - inset)
            let frame = Self.fittedRect(in: available, aspectRatio: aspectRatio).offsetBy(dx: inset, dy: inset)
            ZStack {
                LiveFrame(liveView: liveView)
                    .frame(width: frame.width, height: frame.height)
                    .overlay(Rectangle().strokeBorder(Theme.divider, lineWidth: 1))
                    .position(x: frame.midX, y: frame.midY)
                LiveOverlays(liveView: liveView)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .allowsHitTesting(false)
                if liveView.imageSize == nil {
                    ProgressView("Starting live view…")
                }
                if liveView.showsRulers {
                    GuideLines(liveView: liveView, image: frame)
                    Rulers(liveView: liveView, image: frame, size: geometry.size)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { tap in
                    onClick(Self.point(tap.location, in: frame))
                }
            )
            .coordinateSpace(.named(Rulers.space))
        }
    }

    /// `location` as a fraction of `rect`, or nil outside it.
    private static func point(_ location: CGPoint, in rect: CGRect) -> LiveViewPoint? {
        guard rect.width > 0, rect.height > 0, rect.contains(location) else { return nil }
        return .init(x: (location.x - rect.minX) / rect.width, y: (location.y - rect.minY) / rect.height)
    }

    private var aspectRatio: Double {
        guard let size = liveView.imageSize, size.height > 0 else { return Self.defaultAspectRatio }
        return size.width / size.height
    }

    /// The largest rectangle of `aspectRatio` that fits `size`, centred.
    private static func fittedRect(in size: CGSize, aspectRatio: Double) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let width = min(size.width, size.height * aspectRatio)
        let height = width / aspectRatio
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}

/// The current frame — the one view that changes 30 times a second.
private struct LiveFrame: View {
    let liveView: LiveViewModel

    var body: some View {
        LayerImage(image: liveView.image, marks: liveView.peakingMarks)
            .accessibilityElement()
            .accessibilityAddTraits(.isImage)
            .accessibilityLabel("Live view")
    }
}

/// Shows an image, and focus-peaking marks over it, by swapping layers'
/// contents: no SwiftUI image pipeline per frame, and the marks change in
/// the same transaction as the frame they belong to.
private struct LayerImage: NSViewRepresentable {
    let image: CGImage?
    let marks: CGImage?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspect
        view.layer?.backgroundColor = NSColor.black.cgColor
        let marksLayer = CALayer()
        // Never animated, so the marks don't slide off the frame while the
        // window resizes.
        marksLayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        marksLayer.contentsGravity = .resizeAspect
        marksLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(marksLayer)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        CATransaction.begin()
        // No cross-fade between frames.
        CATransaction.setDisableActions(true)
        view.layer?.contents = image
        if let marksLayer = view.layer?.sublayers?.first {
            marksLayer.frame = view.bounds
            marksLayer.contents = marks
        }
        CATransaction.commit()
    }
}

/// Reference image, grid and centre cross.
private struct LiveOverlays: View {
    let liveView: LiveViewModel

    var body: some View {
        ZStack {
            if liveView.showsOverlay, let overlay = liveView.overlayImage {
                // Fitted, not stretched: a reference from this camera has the
                // live view's shape and fills it exactly.
                Image(decorative: overlay, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(liveView.overlayOpacity)
            }
            // A dark shadow keeps the guides visible on bright subjects.
            if liveView.showsGrid {
                ThirdsGrid().stroke(.white.opacity(0.5), lineWidth: 1)
                    .shadow(color: .black.opacity(0.7), radius: 0, x: 0.5, y: 0.5)
            }
            if liveView.showsCrosshair {
                Crosshair().stroke(.white.opacity(0.9), lineWidth: 1)
                    .shadow(color: .black.opacity(0.7), radius: 0, x: 0.5, y: 0.5)
            }
            CameraFrames(frames: liveView.cameraFrames)
        }
    }
}

/// The camera's AF frames, faces and tracked subjects, as the camera draws
/// them: white, green once in focus, orange while being moved.
private struct CameraFrames: View {
    let frames: [LiveViewFrame]

    var body: some View {
        GeometryReader { geometry in
            ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Self.color(frame.state), lineWidth: frame.state == .focused ? 2 : 1.5)
                    .shadow(color: .black.opacity(0.7), radius: 0, x: 0.5, y: 0.5)
                    .frame(width: frame.width * geometry.size.width, height: frame.height * geometry.size.height)
                    .position(x: frame.centre.x * geometry.size.width, y: frame.centre.y * geometry.size.height)
            }
        }
        .accessibilityHidden(true)
    }

    private static func color(_ state: LiveViewFrame.State) -> Color {
        switch state {
        case .focused: Theme.success
        case .selecting, .moving: Theme.focus
        default: .white.opacity(0.9)
        }
    }
}

/// Rule-of-thirds lines.
private struct ThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            for fraction in [1.0 / 3, 2.0 / 3] {
                let x = rect.minX + rect.width * fraction
                let y = rect.minY + rect.height * fraction
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
    }
}

/// A cross through the centre.
private struct Crosshair: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = min(rect.width, rect.height) * 0.04
        return Path { path in
            path.move(to: CGPoint(x: rect.midX - arm, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX + arm, y: rect.midY))
            path.move(to: CGPoint(x: rect.midX, y: rect.midY - arm))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.midY + arm))
        }
    }
}
