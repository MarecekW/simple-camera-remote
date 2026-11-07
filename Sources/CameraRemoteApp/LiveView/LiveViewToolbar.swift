import CaptureCore
import SonyRemote
import SwiftUI
import UniformTypeIdentifiers

/// View options for the live view: guides, the reference overlay and the
/// histogram; and review of the last capture, with measuring on it.
struct LiveViewToolbar: View {
    @Bindable var liveView: LiveViewModel
    let camera: SonyCamera
    let controls: CameraControls
    @Bindable var review: ReviewModel
    let capture: CaptureModel

    /// Whether there's a capture to review.
    private var canReview: Bool { capture.lastCapture?.jpeg != nil }
    /// Off while a text field is being edited, so the letters type instead.
    private var shortcutsEnabled: Bool { !capture.isEditingText }
    @State private var showsOverlaySettings = false
    @State private var choosesOverlay = false
    @State private var overlayError: String?

    var body: some View {
        // Tight within a group of chips, wider around the dividers between groups.
        HStack(spacing: 6) {
            Toggle(isOn: $liveView.showsGrid) { Label("Grid", systemImage: "grid") }
                .keyboardShortcut(shortcut("g"))
                .help("Rule-of-thirds grid (G)")
            Toggle(isOn: $liveView.showsCrosshair) { Label("Centre", systemImage: "plus.viewfinder") }
                .keyboardShortcut(shortcut("c"))
                .help("Centre cross (C)")
            Toggle(isOn: $liveView.showsHistogram) { Label("Histogram", systemImage: "chart.bar") }
                .keyboardShortcut(shortcut("h"))
                .help("Live histogram (H)")
            Toggle(isOn: $liveView.showsPeaking) { Label("Peaking", systemImage: "scope") }
                .keyboardShortcut(shortcut("p"))
                .help("Focus peaking (P): in-focus detail in green. Right-click for sensitivity.")
                .contextMenu {
                    Picker("Sensitivity", selection: $liveView.peakingSensitivity) {
                        Text("Low: strong edges only").tag(FocusPeaking.Sensitivity.low)
                        Text("Medium").tag(FocusPeaking.Sensitivity.medium)
                        Text("High: faint detail too").tag(FocusPeaking.Sensitivity.high)
                    }
                    .pickerStyle(.inline)
                }
            Toggle(isOn: $liveView.showsRulers) { Label("Rulers", systemImage: "ruler") }
                .keyboardShortcut(shortcut("u"))
                .help("Rulers and guides (U): drag from a ruler to place a guide")
                .contextMenu {
                    Button("Clear Guides", action: liveView.clearGuides)
                        .disabled(liveView.guides.all.isEmpty)
                }
            magnifier
            Divider().frame(height: 16).padding(.horizontal, 4)
            // One control: the chip shows or hides the overlay (or, with none
            // chosen yet, opens the settings); the chevron opens the settings.
            HStack(spacing: 2) {
                if liveView.overlayImage != nil {
                    Toggle(isOn: $liveView.showsOverlay) { Label("Overlay", systemImage: "square.on.square") }
                        .keyboardShortcut(shortcut("o"))
                        .help("Reference overlay: \(liveView.overlayName ?? "") (O)")
                } else {
                    Button {
                        showsOverlaySettings = true
                    } label: {
                        Label("Overlay…", systemImage: "square.on.square")
                    }
                    .buttonStyle(ChipButtonStyle())
                    .help("Choose a reference image to overlay on the live view")
                }
                Button {
                    showsOverlaySettings.toggle()
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: Layout.controlHeight)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(Theme.textSecondary)
                .help("Overlay image and opacity")
                .accessibilityLabel("Overlay settings")
            }
            .popover(isPresented: $showsOverlaySettings, arrowEdge: .bottom) {
                OverlaySettings(liveView: liveView, error: overlayError) {
                    showsOverlaySettings = false
                    choosesOverlay = true
                }
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            reviewControls
            Spacer()
            if review.isMeasuring {
                MeasureBar(review: review, capture: capture)
            } else if review.isShown {
                ReviewMeasurements(review: review)
            } else {
                FrameRate(liveView: liveView)
            }
        }
        .toggleStyle(ChipToggleStyle())
        .buttonStyle(.borderless)
        .labelStyle(ToolbarLabelStyle())
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: Layout.toolbarHeight)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Theme.divider.frame(height: 1) }
        .fileImporter(isPresented: $choosesOverlay, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            Task {
                let loaded = await liveView.chooseOverlay(url)
                overlayError = loaded ? nil : "\(url.lastPathComponent) couldn't be read as an image."
                showsOverlaySettings = !loaded
            }
        }
    }
}

extension LiveViewToolbar {
    /// The camera's focus magnifier: real sensor detail, unlike enlarging
    /// the live view.  Each click goes to the next magnification, then off.
    @ViewBuilder
    private var magnifier: some View {
        if !camera.magnifierRatios.isEmpty {
            Button {
                controls.cycleMagnification(on: camera)
            } label: {
                Label {
                    // Wide enough for the longest label, so the toolbar
                    // doesn't shift as the magnification changes.
                    Text(camera.magnification.map { "×\($0.formatted())" } ?? "Magnify")
                        .frame(minWidth: 52, alignment: .leading)
                } icon: {
                    Image(systemName: "plus.magnifyingglass")
                }
            }
            .buttonStyle(ChipButtonStyle(isSelected: camera.magnification != nil))
            .keyboardShortcut(shortcut("m"))
            .help(
                "Focus magnifier (M): ×\(camera.magnifierRatios.map { $0.formatted() }.joined(separator: ", ×")), "
                    + "then off. Click the live view to move the magnified area."
            )
            .accessibilityValue(camera.magnification.map { "×\($0.formatted())" } ?? "off")
        }
    }

    /// Review of the last capture, and while reviewing its zoom and the
    /// clipping map.
    @ViewBuilder
    private var reviewControls: some View {
        Toggle(isOn: $review.isShown) { Label("Review", systemImage: "photo") }
            .keyboardShortcut(shortcut("r"))
            .disabled(!canReview && !review.isShown)
            .help("Review the last capture at full resolution (R)")
        if review.isShown {
            Button {
                review.zoom = review.zoom == .fit ? .actualSize : .fit
            } label: {
                Text(review.zoom == .fit ? "Fit" : "100 %").frame(minWidth: 38)
            }
            .buttonStyle(ChipButtonStyle())
            .keyboardShortcut(shortcut("z"))
            .help("Fit or 100 % (Z, or double-click the image)")
            Toggle(isOn: $review.showsClipping) { Label("Clipping", systemImage: "exclamationmark.square") }
                .keyboardShortcut(shortcut("k"))
                .help("Blown highlights in red, crushed shadows in blue (K)")
            Toggle(isOn: $review.isMeasuring) { Label("Measure", systemImage: "lines.measurement.horizontal") }
                .disabled(review.analysis == nil)
                .help("Measure the scale: click both ends of a known length, e.g. on a ruler, then enter it in mm")
        }
    }

    private func shortcut(_ key: Character) -> KeyboardShortcut? {
        shortcutsEnabled ? KeyboardShortcut(KeyEquivalent(key), modifiers: []) : nil
    }
}

/// Icon and title centred on one line, each icon in the same box.  The
/// default style aligns on text baselines, which sets symbols of different
/// heights (grid vs. viewfinder) at different heights.
private struct ToolbarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .frame(width: 16, height: 16)
            configuration.title
        }
    }
}

/// The live frame rate — its own view, as it changes with every frame.
private struct FrameRate: View {
    let liveView: LiveViewModel

    var body: some View {
        Text("\(liveView.framesPerSecond) fps")
            .monospacedDigit()
            .foregroundStyle(Theme.textSecondary)
            .accessibilityLabel("\(liveView.framesPerSecond) frames per second")
    }
}

/// The reviewed capture's sharpness and clipping.
private struct ReviewMeasurements: View {
    let review: ReviewModel

    var body: some View {
        if let analysis = review.analysis {
            HStack(spacing: 12) {
                if let sharpness = analysis.sharpness {
                    Text("Sharpness \(Int(sharpness.rounded()))")
                        .help("Variance of the Laplacian over the image's centre: compare shots of the same setup")
                }
                Text("Blown \(Self.percent(analysis.highlightClipping))")
                    .foregroundStyle(analysis.highlightClipping > 0.001 ? Theme.warning : Theme.textSecondary)
                Text("Black \(Self.percent(analysis.shadowClipping))")
                    .foregroundStyle(analysis.shadowClipping > 0.001 ? Theme.warning : Theme.textSecondary)
            }
            .monospacedDigit()
            .foregroundStyle(Theme.textSecondary)
        } else if case .loading = review.state {
            ProgressView().controlSize(.small)
        }
    }

    private static func percent(_ fraction: Double) -> String {
        (fraction * 100).formatted(.number.precision(.fractionLength(1))) + " %"
    }
}

/// Measuring on the reviewed capture: the clicked length in image pixels,
/// its length in millimetres as typed, and the scale they give — kept for
/// the session with Use.
private struct MeasureBar: View {
    let review: ReviewModel
    let capture: CaptureModel

    @State private var millimetresText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let pixels = review.measuredPixels {
                Text("\(pixels.formatted(.number.precision(.fractionLength(1)))) px =")
                TextField("mm", text: $millimetresText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 6)
                    .frame(width: 64)
                    .panelBox(fill: Theme.background)
                    .focused($isFocused)
                    .onSubmit(use)
                Text("mm")
                if let scale = scale(pixels) {
                    Text("→ \(scale.pixelsPerMillimetre.formatted(.number.precision(.fractionLength(2)))) px/mm")
                        .foregroundStyle(Theme.textPrimary)
                }
                Button("Use", action: use)
                    .buttonStyle(ChipButtonStyle())
                    .disabled(scale(pixels) == nil || capture.isCapturing)
                    .help("Keep this scale for the session: later captures record it (Return)")
            } else {
                Text(review.measuredEnds.isEmpty ? "Click one end of a known length" : "Click the other end")
            }
        }
        .monospacedDigit()
        .foregroundStyle(Theme.textSecondary)
        .onChange(of: isFocused) { _, focused in capture.isEditingText = focused }
        .onDisappear { capture.isEditingText = false }
    }

    /// The scale for the typed length, in the user's locale (e.g. with a
    /// decimal comma); nil until it's a length.
    private func scale(_ pixels: Double) -> MeasuredScale? {
        guard let reviewed = review.capture,
            let millimetres = try? Double(millimetresText.trimmingCharacters(in: .whitespaces), format: .number)
        else { return nil }
        return MeasuredScale(
            pixels: pixels, millimetres: millimetres, capture: reviewed.name, focalLength: reviewed.focalLength)
    }

    private func use() {
        guard let pixels = review.measuredPixels, let scale = scale(pixels) else { return }
        capture.setMeasuredScale(scale)
        review.isMeasuring = false
    }
}

/// How strongly the reference image shows, and replacing or removing it.
private struct OverlaySettings: View {
    @Bindable var liveView: LiveViewModel
    let error: String?
    let chooseImage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reference overlay").font(.headline)
            Text("An image laid over the live view to position each sample the same way.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choose Image…", action: chooseImage)
                if liveView.overlayImage != nil {
                    Button("Remove", role: .destructive) { liveView.clearOverlay() }
                }
            }
            if let error {
                Text(error).foregroundStyle(Theme.failure)
            }
            LabeledContent("Opacity") {
                Slider(value: $liveView.overlayOpacity, in: 0.05...1)
                    .frame(width: 160)
            }
            .disabled(liveView.overlayImage == nil)
        }
        .padding(16)
        .frame(width: 300)
    }
}
