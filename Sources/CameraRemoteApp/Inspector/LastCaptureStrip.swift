import ImageIO
import SwiftUI

/// The newest capture: a thumbnail, its name and files, using it as the
/// positioning overlay, and deleting it for a retake.
struct LastCaptureStrip: View {
    let capture: CaptureModel
    let liveView: LiveViewModel
    @State private var thumbnail: CGImage?
    @State private var isDeleteAsked = false

    private var last: LastCapture? { capture.lastCapture }

    var body: some View {
        HStack(spacing: Layout.labelGap) {
            // The picture and its name show the files in Finder.
            Button(action: showInFinder) {
                HStack(spacing: Layout.labelGap) {
                    thumbnailView
                        .frame(width: Layout.inspectorLabelWidth, alignment: .leading)
                    details
                        .padding(.leading, Layout.valueInset)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(last == nil)
            .help(last.map { "Show \($0.name) in Finder" } ?? "")
            Menu {
                Button("Use as Overlay") {
                    if let jpeg = last?.jpeg { Task { _ = await liveView.chooseOverlay(jpeg) } }
                }
                .disabled(last?.jpeg == nil)
                Button("Show in Finder", action: showInFinder)
                Button("Open JPEG") {
                    if let jpeg = last?.jpeg { NSWorkspace.shared.open(jpeg) }
                }
                .disabled(last?.jpeg == nil)
                Divider()
                Button("Delete Last Shot…") { isDeleteAsked = true }
                    .disabled(capture.isCapturing || capture.isOpeningSession)
            } label: {
                DockMenuIcon(systemName: "ellipsis")
            }
            .dockMenuStyle()
            .disabled(last == nil)
            .accessibilityLabel("Last capture options")
        }
        .frame(height: 36)
        .task(id: last?.jpeg) {
            // Also cleared for a capture without a JPEG, e.g. after a delete.
            thumbnail = nil
            guard let jpeg = last?.jpeg else { return }
            thumbnail = await Self.thumbnail(of: jpeg)
        }
        .confirmationDialog(
            "Delete “\(last?.name ?? "")”?", isPresented: $isDeleteAsked, presenting: last
        ) { last in
            Button("Delete", role: .destructive) { Task { await capture.deleteLastCapture(last.sequence) } }
        } message: { _ in
            Text(deletionNote)
        }
    }

    private var deletionNote: String {
        let retake = capture.session.sample == nil ? "the same name" : "the same name, load, side and strips"
        return "Its files and sidecar go to the Trash and its row leaves the session log; the retake gets \(retake). "
            + "The copy on the camera's card is kept."
    }

    private var thumbnailView: some View {
        Group {
            if let thumbnail, last != nil {
                Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 54, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Layout.cornerRadius).strokeBorder(Theme.divider, lineWidth: 1))
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let last {
                Text(last.name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label(Self.summary(of: last), systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(Theme.success)
                    .lineLimit(1)
            } else {
                Text("No captures yet")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// "RAW + JPEG · 45.2 MB · 14:32".
    private static func summary(of capture: LastCapture) -> String {
        let kinds = capture.files.map { url in
            switch url.pathExtension.uppercased() {
            case "ARW": "RAW"
            case "JPG": "JPEG"
            case let other: other
            }
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(capture.bytes), countStyle: .file)
        return [kinds.joined(separator: " + "), size, capture.capturedAt.formatted(date: .omitted, time: .shortened)]
            .joined(separator: " · ")
    }

    private func showInFinder() {
        guard let last else { return }
        NSWorkspace.shared.activateFileViewerSelecting(last.files)
    }

    @concurrent
    private static func thumbnail(of url: URL) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
