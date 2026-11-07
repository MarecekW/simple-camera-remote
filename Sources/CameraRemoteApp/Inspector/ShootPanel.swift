import CaptureCore
import SonyRemote
import SwiftUI

/// The capture workflow at a glance — the last shot, which side is next, the
/// next file name, what blocks the shutter — and the shutter itself.
struct ShootPanel: View {
    let camera: SonyCamera
    let capture: CaptureModel
    let liveView: LiveViewModel
    let controls: CameraControls

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Every row is always there, so the dock never changes height.
            LastCaptureStrip(capture: capture, liveView: liveView)
            if let sample = capture.session.sample {
                LoadProgress(capture: capture, sample: sample)
            } else {
                CaptureCounter(capture: capture)
            }
            NextFile(camera: camera, capture: capture)
            HStack(spacing: Layout.labelGap) {
                focusButton
                shootButton
            }
        }
        .padding(Layout.inspectorPadding)
        .background(Theme.dock)
        .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
        .shadow(color: .black.opacity(0.35), radius: 6, y: -2)
    }

    /// The shutter's half press while held, beside the shutter: focuses in
    /// AF modes; in MF it steadies the image without changing focus.
    private var focusButton: some View {
        HoldButton(
            title: "Autofocus",
            help: camera.isAutofocusing
                ? "Half press while held: autofocus (key A)"
                : "Half press while held: steadies the image; in MF it doesn't focus (key A). "
                    + "DMF autofocuses and lets you fine-tune by hand.",
            height: Self.shutterHeight, tint: Theme.focus
        ) { pressed in
            controls.autofocus(pressed, on: camera)
        } label: {
            Label("AF", systemImage: "scope")
                .labelStyle(.titleAndIcon)
        }
        .frame(width: Layout.inspectorLabelWidth)
        .disabled(capture.isCapturing)
    }

    private static let shutterHeight: CGFloat = 38

    private var shootButton: some View {
        Button {
            Task { await capture.shoot() }
        } label: {
            HStack(spacing: 8) {
                if capture.isCapturing {
                    ProgressView().controlSize(.small)
                    Text("Saving…")
                } else {
                    // A plain camera: the shutter-button glyph's top knob
                    // makes it sit low against the text.
                    Label("Shoot", systemImage: "camera.fill")
                        .labelStyle(.titleAndIcon)
                }
                Spacer(minLength: 0)
                // Space types into a text field being edited instead.
                if !capture.isEditingText {
                    Text("Space")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.15), in: Capsule())
                }
            }
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: Self.shutterHeight)
        }
        .buttonStyle(ShutterButtonStyle())
        .disabled(capture.blockedReason != nil)
        .keyboardShortcut(capture.isEditingText ? nil : KeyboardShortcut(.space, modifiers: []))
        .help(capture.blockedReason ?? "Take a picture (Space or ⌘K)")
    }
}

/// The load on the rig and its sides: shot sides filled, the next side in
/// a white outline.  Clicking a side makes it the next one.
private struct LoadProgress: View {
    let capture: CaptureModel
    let sample: SampleWorkflow

    var body: some View {
        HStack(spacing: Layout.labelGap) {
            DockLabel("LOAD \(sample.load)")
            HStack(spacing: Layout.cellGap) {
                // The sides span three grid columns, Next Load the fourth.
                HStack(spacing: Layout.cellGap) {
                    ForEach(1...SampleWorkflow.sidesPerLoad, id: \.self) { side in
                        Button {
                            capture.setSide(side)
                        } label: {
                            Text("\(side)")
                                .font(.callout.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: Layout.controlHeight)
                                .foregroundStyle(foreground(side))
                                .background(RoundedRectangle(cornerRadius: Layout.cornerRadius).fill(fill(side)))
                                .overlay(
                                    RoundedRectangle(cornerRadius: Layout.cornerRadius)
                                        .strokeBorder(
                                            side == sample.side ? Theme.textPrimary : Theme.divider,
                                            lineWidth: side == sample.side ? 1.5 : 1)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(
                            side < sample.side
                                ? "Side \(side) shot — click to shoot it again" : "Shoot side \(side) next (] / [)"
                        )
                        .accessibilityLabel("Side \(side)")
                        .accessibilityValue(side < sample.side ? "shot" : side == sample.side ? "next" : "to do")
                    }
                }
                Button("Next") { capture.startNextLoad() }
                    .buttonStyle(PanelButtonStyle())
                    .frame(width: Layout.cell)
                    .help("Next load: put the next strips on the rig and start again at side 1 (⌘N)")
                    .accessibilityLabel("Next Load")
            }
        }
        .disabled(capture.isCapturing)
    }

    private func fill(_ side: Int) -> Color {
        side < sample.side ? Theme.chipOn : side == sample.side ? Theme.panelRaised : .clear
    }

    private func foreground(_ side: Int) -> Color {
        side < sample.side ? .black : side == sample.side ? Theme.textPrimary : Theme.textSecondary
    }
}

/// Outside the sample workflow, in place of the load row: the number of the
/// next capture.
private struct CaptureCounter: View {
    let capture: CaptureModel

    var body: some View {
        HStack(spacing: Layout.labelGap) {
            DockLabel("SHOT")
            InspectorValue("\(capture.session.nextSequence)")
                .font(.callout.weight(.semibold).monospacedDigit())
            Spacer(minLength: 0)
        }
        .frame(height: Layout.controlHeight)
    }
}

/// The name the next capture's files will get, and the files the camera's
/// format makes; values still missing show as ‹placeholders› in amber.
private struct NextFile: View {
    let camera: SonyCamera
    let capture: CaptureModel

    var body: some View {
        HStack(spacing: Layout.labelGap) {
            HStack(alignment: .firstTextBaseline, spacing: Layout.labelGap) {
                DockLabel("NEXT")
                Group {
                    if let preview = capture.nextFilePreview {
                        Text(Self.highlighted(preview))
                    } else {
                        Text("Camera's own name").foregroundStyle(Theme.textSecondary)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.leading, Layout.valueInset)
                .help(
                    capture.nextFilePreview.map { $0 + fileTypes } ?? "Files keep the camera's names, e.g. DSC01135.ARW"
                )
            }
            Spacer(minLength: 0)
            CalibrationMenu(capture: capture)
        }
    }

    /// " .ARW .JPG" for RAW+JPEG, for the tooltip — the row keeps its width
    /// for the name; nothing while the format is unknown.
    private var fileTypes: String {
        switch camera.properties[.fileFormat]?.currentValue.bitPattern.map(FileFormat.init(rawValue:)) {
        case .raw?: " .ARW"
        case .jpeg?: " .JPG"
        case .rawAndJPEG?: " .ARW .JPG"
        default: ""
        }
    }

    /// Placeholders (‹…›) in amber, the rest in primary text.
    private static func highlighted(_ preview: String) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(preview)
        while let open = rest.firstIndex(of: "‹"), let close = rest[open...].firstIndex(of: "›") {
            var plain = AttributedString(rest[..<open])
            plain.foregroundColor = Theme.textPrimary
            var placeholder = AttributedString(rest[open...close])
            placeholder.foregroundColor = Theme.warning
            result += plain + placeholder
            rest = rest[rest.index(after: close)...]
        }
        var tail = AttributedString(rest)
        tail.foregroundColor = Theme.textPrimary
        return result + tail
    }
}

/// Marks the next shot as a calibration frame — a ColorChecker, white card or
/// ruler instead of strips.  Lit while set; the NEXT name shows the tag.
private struct CalibrationMenu: View {
    @Bindable var capture: CaptureModel

    var body: some View {
        let target = capture.nextCalibration
        let tint = target == nil ? Theme.textPrimary : Theme.warning
        Menu {
            Picker("Calibration Frame", selection: $capture.nextCalibration) {
                Text("None").tag(CalibrationTarget?.none)
                ForEach(CalibrationTarget.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
            }
            .pickerStyle(.inline)
        } label: {
            DockMenuIcon(systemName: target == nil ? "tag" : "tag.fill", tint: tint)
        }
        .dockMenuStyle(tint: tint)
        .disabled(capture.isCapturing)
        .help(
            target.map { "The next shot is a \($0.label) calibration frame; it keeps the side" }
                ?? "Mark the next shot as a calibration frame (ColorChecker, white card, ruler)"
        )
        .accessibilityLabel("Calibration frame")
        .accessibilityValue(target?.label ?? "none")
    }
}
