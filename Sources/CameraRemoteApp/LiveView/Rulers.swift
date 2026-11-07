import AppKit
import CaptureCore
import SwiftUI

/// Photoshop-style rulers along the top and left of the live view, marked in
/// the capture's pixels (the A6700's 3:2 frame at size L), with guides
/// dragged out of them.  Everything is laid out in the pane's coordinate
/// space (`space`).
struct Rulers: View {
    let liveView: LiveViewModel
    /// The image's rectangle in the pane.
    let image: CGRect
    let size: CGSize

    static let thickness: CGFloat = 18
    static let space = "liveViewPane"
    /// The capture the marks count.
    static let sensor = ResolutionEstimate.Sensor.a6700

    /// The guide being dragged out; reset by SwiftUI if the drag is cut
    /// short, so the next drag starts a new guide.
    @GestureState private var draggedGuide: UUID?

    var body: some View {
        ZStack(alignment: .topLeading) {
            RulerMarks(edge: .top, image: image, length: size.width)
                .frame(width: size.width, height: Self.thickness)
                .gesture(dragOut(.horizontal))
                .modifier(RulerMenu(liveView: liveView))
            RulerMarks(edge: .left, image: image, length: size.height)
                .frame(width: Self.thickness, height: size.height)
                .gesture(dragOut(.vertical))
                .modifier(RulerMenu(liveView: liveView))
            Theme.panel.frame(width: Self.thickness, height: Self.thickness)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// Dragging from the top ruler places a horizontal guide, from the left
    /// one a vertical guide.
    private func dragOut(_ axis: Guides.Guide.Axis) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .updating($draggedGuide) { drag, guide, _ in
                let position = Self.position(of: drag.location, along: axis, in: image)
                if let guide {
                    liveView.moveGuide(guide, to: position)
                } else {
                    guide = liveView.beginGuide(axis, at: position)
                }
            }
            .onEnded { _ in liveView.endGuideFromRuler() }
    }

    /// `location` as a fraction down (horizontal guides) or across
    /// (vertical guides) `image`.
    static func position(of location: CGPoint, along axis: Guides.Guide.Axis, in image: CGRect) -> Double {
        switch axis {
        case .horizontal: image.height > 0 ? (location.y - image.minY) / image.height : 0
        case .vertical: image.width > 0 ? (location.x - image.minX) / image.width : 0
        }
    }

    /// A position as the capture's pixels, e.g. "2064 px".
    static func pixelText(_ position: Double, along axis: Guides.Guide.Axis) -> String {
        let total = axis == .horizontal ? sensor.pixelsDown : sensor.pixelsAcross
        return "\(Int((position * Double(total)).rounded())) px"
    }
}

/// The rulers' tooltip and their menu, on the rulers only.
private struct RulerMenu: ViewModifier {
    let liveView: LiveViewModel

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Clear Guides", action: liveView.clearGuides)
                    .disabled(liveView.guides.all.isEmpty)
            }
            .help("Drag from a ruler to place a guide; drag a guide back onto a ruler to remove it")
    }
}

/// One ruler's marks: long with a number every major step, short between.
private struct RulerMarks: View {
    enum Edge { case top, left }

    let edge: Edge
    let image: CGRect
    /// The ruler's length, the pane's width or height.
    let length: CGFloat

    var body: some View {
        Canvas { context, size in
            let start = edge == .top ? image.minX : image.minY
            let extent = edge == .top ? image.width : image.height
            let total = edge == .top ? Rulers.sensor.pixelsAcross : Rulers.sensor.pixelsDown
            guard extent > 0 else { return }
            let pointsPerPixel = extent / Double(total)
            // A number at least every ~70 points.
            let major = [250, 500, 1000, 2000].first { Double($0) * pointsPerPixel >= 70 } ?? 2000
            for value in stride(from: 0, through: total, by: major / 5) {
                let offset = start + Double(value) * pointsPerPixel
                let isMajor = value.isMultiple(of: major)
                let tick = isMajor ? Rulers.thickness * 0.6 : Rulers.thickness * 0.25
                var path = Path()
                if edge == .top {
                    path.move(to: CGPoint(x: offset, y: size.height))
                    path.addLine(to: CGPoint(x: offset, y: size.height - tick))
                } else {
                    path.move(to: CGPoint(x: size.width, y: offset))
                    path.addLine(to: CGPoint(x: size.width - tick, y: offset))
                }
                context.stroke(path, with: .color(Theme.textTertiary), lineWidth: 1)
                // Numbers that would run off the ruler's end are left out.
                guard isMajor, offset + 30 < length else { continue }
                let label = context.resolve(
                    Text(verbatim: String(value)).font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary))
                if edge == .top {
                    context.draw(label, at: CGPoint(x: offset + 3, y: 2), anchor: .topLeading)
                } else {
                    // Rotated, like Photoshop's left ruler.
                    var rotated = context
                    rotated.translateBy(x: 2, y: offset + 3)
                    rotated.rotate(by: .degrees(90))
                    rotated.draw(label, at: .zero, anchor: .bottomLeading)
                }
            }
        }
        .background(Theme.panel)
        .overlay(alignment: edge == .top ? .bottom : .trailing) {
            if edge == .top {
                Theme.divider.frame(height: 1)
            } else {
                Theme.divider.frame(width: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The guides over the image: thin cyan lines that can be dragged, and off
/// the image to remove them.
struct GuideLines: View {
    let liveView: LiveViewModel
    let image: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(liveView.guides.all) { guide in
                GuideLine(liveView: liveView, guide: guide, image: image)
            }
        }
    }
}

/// One guide: a line with a wider grab area, its position shown while it's
/// dragged, and a resize cursor while hovered.
private struct GuideLine: View {
    let liveView: LiveViewModel
    let guide: Guides.Guide
    let image: CGRect

    @GestureState private var isDragging = false
    /// Whether this view pushed the cursor, so it pops it exactly once —
    /// also when the guide goes away under the pointer.
    @State private var hasPushedCursor = false

    private static let hitWidth: CGFloat = 7

    var body: some View {
        let isHorizontal = guide.axis == .horizontal
        let point =
            isHorizontal
            ? CGPoint(x: image.midX, y: image.minY + guide.position * image.height)
            : CGPoint(x: image.minX + guide.position * image.width, y: image.midY)
        ZStack {
            Theme.guide.frame(width: isHorizontal ? image.width : 1, height: isHorizontal ? 1 : image.height)
        }
        .frame(
            width: isHorizontal ? image.width : Self.hitWidth, height: isHorizontal ? Self.hitWidth : image.height
        )
        .contentShape(Rectangle())
        .overlay {
            if isDragging {
                Text(Rulers.pixelText(guide.position, along: guide.axis))
                    .font(.system(size: 10).monospacedDigit())
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .background(Theme.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(Theme.textPrimary)
                    .offset(x: isHorizontal ? 0 : 40, y: isHorizontal ? -12 : 0)
            }
        }
        .position(point)
        .onHover { isInside in
            if isInside, !hasPushedCursor {
                (isHorizontal ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push()
                hasPushedCursor = true
            } else if !isInside {
                popCursor()
            }
        }
        .onDisappear(perform: popCursor)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Rulers.space))
                .updating($isDragging) { _, dragging, _ in dragging = true }
                .onChanged { drag in
                    liveView.moveGuide(guide.id, to: Rulers.position(of: drag.location, along: guide.axis, in: image))
                }
                .onEnded { _ in liveView.endGuide(guide.id) }
        )
        .help(Rulers.pixelText(guide.position, along: guide.axis) + " — drag onto a ruler to remove")
    }

    private func popCursor() {
        guard hasPushedCursor else { return }
        NSCursor.pop()
        hasPushedCursor = false
    }
}
