import CaptureCore
import SwiftUI

/// The three channel histograms; overlapping channels add up to white, as on
/// the camera.
struct HistogramPanel: View {
    let liveView: LiveViewModel
    let review: ReviewModel

    /// The reviewed capture's while reviewing, else the live view's.
    private var histogram: Histogram? {
        review.isShown ? review.analysis?.histogram : liveView.histogram
    }

    var body: some View {
        Canvas { context, size in
            guard let histogram else { return }
            context.blendMode = .plusLighter
            for (bins, color) in [(histogram.red, Color.red), (histogram.green, .green), (histogram.blue, .blue)] {
                context.fill(Self.path(for: bins, in: size), with: .color(color.opacity(0.7)))
            }
        }
        .overlay {
            if histogram == nil {
                Text("No histogram")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Layout.cornerRadius).strokeBorder(Theme.divider, lineWidth: 1))
        .accessibilityElement()
        .accessibilityLabel("Histogram")
        .accessibilityValue(clippingDescription)
    }

    private var clippingDescription: String {
        guard let histogram else { return "unavailable" }
        return String(format: "%.1f %% of samples at full brightness", histogram.clippedSampleFraction * 100)
    }

    /// Bars scaled to the tallest bin, ignoring the end bins so a few clipped
    /// pixels don't flatten the rest.
    private static func path(for bins: [Int], in size: CGSize) -> Path {
        let peak = max(bins.dropFirst().dropLast().max() ?? 1, 1)
        let step = size.width / CGFloat(bins.count - 1)
        return Path { path in
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, count) in bins.enumerated() {
                let height = min(CGFloat(count) / CGFloat(peak), 1) * size.height
                path.addLine(to: CGPoint(x: CGFloat(index) * step, y: size.height - height))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        }
    }
}
