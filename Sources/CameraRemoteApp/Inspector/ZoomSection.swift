import CaptureCore
import SonyProtocol
import SonyRemote
import SwiftUI

/// Power zoom: where the lens is in its range, zooming while W / T is held,
/// and up to three saved positions labelled with their focal length.  Going
/// to a typed focal length is in the ⋯ menu.
struct ZoomSection: View {
    let camera: SonyCamera
    let controls: CameraControls
    let positions: ZoomPositions
    let capture: CaptureModel
    let advisories: [Advisory]

    @State private var isGoToShown = false

    var body: some View {
        InspectorSection(
            "Zoom", id: "zoom", summary: Text(focalLengthText), advisories: advisories.messages(for: [.focalLength])
        ) {
            // One four-column grid for the whole section: the readout sits
            // over the first zoom button, the gauge over the other three.
            InspectorRow("Focal", advisory: advisories.message(for: .focalLength)) {
                HStack(spacing: Layout.cellGap) {
                    InspectorValue(focalLengthText)
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .frame(width: Layout.cell, alignment: .leading)
                    RangeGauge(camera: camera, positions: positions)
                }
            }
            if camera.isZoomAvailable {
                InspectorRow("Zoom") {
                    HStack(spacing: Layout.cellGap) {
                        zoomButton("Zoom wide fast", help: "Wide, fast (⇧W)", speed: -Self.fastSpeed) {
                            HStack(spacing: 1) {
                                Image(systemName: "chevron.left.2").font(.system(size: 9, weight: .bold))
                                Text("W")
                            }
                        }
                        zoomButton("Zoom wide", help: "Wide (W)", speed: -Self.slowSpeed) { Text("W") }
                        zoomButton("Zoom tele", help: "Tele (T)", speed: Self.slowSpeed) { Text("T") }
                        zoomButton("Zoom tele fast", help: "Tele, fast (⇧T)", speed: Self.fastSpeed) {
                            HStack(spacing: 1) {
                                Text("T")
                                Image(systemName: "chevron.right.2").font(.system(size: 9, weight: .bold))
                            }
                        }
                    }
                    .disabled(positions.isMoving || capture.isCapturing)
                }
                InspectorRow("Positions") {
                    HStack(spacing: Layout.cellGap) {
                        ForEach(ZoomPositions.slots, id: \.self) { slot in
                            PositionChip(slot: slot, camera: camera, positions: positions)
                        }
                        Button {
                            isGoToShown = true
                        } label: {
                            Text("mm…")
                        }
                        .buttonStyle(PanelButtonStyle())
                        .help("Go to a focal length")
                        .disabled(positions.isMoving)
                    }
                }
            } else {
                InspectorRow("") {
                    InspectorValue("Fixed or manual zoom")
                        .foregroundStyle(Theme.textSecondary)
                        .help("Power zoom needs a PZ lens")
                }
            }
        } menu: {
            Button("Go to Focal Length…") { isGoToShown = true }
                .disabled(!camera.isZoomAvailable)
            Button("Clear All Positions", action: positions.clearAll)
                .disabled(positions.saved.isEmpty)
        }
        // On the section, so the ⋯ menu's command works while it's collapsed.
        .popover(isPresented: $isGoToShown, arrowEdge: .leading) {
            GoToFocalLength(camera: camera, positions: positions, capture: capture) {
                isGoToShown = false
            }
        }
        .task(id: ObjectIdentifier(camera)) { positions.use(camera) }
    }

    private static let slowSpeed = CameraControls.slowZoomSpeed
    private static let fastSpeed = CameraControls.fastZoomSpeed

    private func zoomButton(
        _ title: String, help: String, speed: Int8, @ViewBuilder label: () -> some View
    ) -> some View {
        HoldButton(title: title, help: help + " — hold to zoom") { pressed in
            controls.zoom(speed: pressed ? speed : 0, on: camera)
        } label: {
            label()
        }
    }

    private var focalLengthText: String {
        camera.focalLength.map { FocalLength(rawValue: $0).description } ?? "—"
    }
}

/// Where the lens is between its ends, as a meter: filled up to the focal
/// length, with the saved positions as ticks.  Read-only — the W / T buttons
/// and positions move the lens.
private struct RangeGauge: View {
    let camera: SonyCamera
    let positions: ZoomPositions

    var body: some View {
        if let range = camera.focalLengthRange, range.upperBound > range.lowerBound {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.panelRaised)
                        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                        .frame(height: 6)
                    if let focal = camera.focalLength {
                        Capsule().fill(Theme.textTertiary)
                            .frame(width: max(6, fraction(focal, in: range) * width), height: 6)
                    }
                    ForEach(positions.saved.keys.sorted(), id: \.self) { slot in
                        if let focal = positions.saved[slot]?.focalLength {
                            Rectangle().fill(Theme.textSecondary)
                                .frame(width: 1, height: 12)
                                .offset(x: fraction(focal, in: range) * (width - 1))
                        }
                    }
                    if let focal = camera.focalLength {
                        Capsule().fill(Theme.textPrimary)
                            .frame(width: 2, height: 12)
                            .offset(x: fraction(focal, in: range) * (width - 2))
                    }
                }
                .frame(height: geometry.size.height)
            }
            .frame(height: Layout.controlHeight)
            .help("Zoom range \(range.lowerBound / 1000)–\(range.upperBound / 1000) mm")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Zoom range \(range.lowerBound / 1000) to \(range.upperBound / 1000) mm")
        }
    }

    private func fraction(_ focal: UInt32, in range: ClosedRange<UInt32>) -> CGFloat {
        let clamped = min(max(focal, range.lowerBound), range.upperBound)
        return CGFloat(clamped - range.lowerBound) / CGFloat(range.upperBound - range.lowerBound)
    }
}

/// A saved position, labelled with its focal length: click to go there.
/// Empty (+), click to save the current one.  Right-click to replace or
/// clear.
private struct PositionChip: View {
    let slot: UInt8
    let camera: SonyCamera
    let positions: ZoomPositions

    var body: some View {
        if let position = positions.saved[slot] {
            Button {
                positions.recall(slot, on: camera)
            } label: {
                Text(FocalLength(rawValue: position.focalLength).description)
            }
            .buttonStyle(PanelButtonStyle())
            .disabled(positions.isMoving || !positions.fits(position, on: camera))
            .help(
                positions.fits(position, on: camera)
                    ? "Go to position \(slot) — exact zoom and focus (⌥\(slot))"
                    : "Saved with \(position.lens ?? "another lens")"
            )
            .contextMenu {
                Button("Replace with Current (\(currentText))") { positions.save(slot, on: camera) }
                Button("Clear") { positions.clear(slot) }
            }
        } else {
            Button {
                positions.save(slot, on: camera)
            } label: {
                Image(systemName: "plus")
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(PanelButtonStyle())
            .help("Save the current zoom and focus (\(currentText)) as position \(slot)")
            .disabled(positions.isMoving)
        }
    }

    private var currentText: String {
        camera.focalLength.map { FocalLength(rawValue: $0).description } ?? "—"
    }
}

/// Typing a focal length to zoom to.
private struct GoToFocalLength: View {
    let camera: SonyCamera
    let positions: ZoomPositions
    let capture: CaptureModel
    let done: () -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("mm", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .focused($isFocused)
                .onSubmit(go)
            Text("mm").foregroundStyle(.secondary)
            Button("Go", action: go)
                .keyboardShortcut(.defaultAction)
                .disabled(millimetres == nil)
        }
        .padding(12)
        .onAppear { isFocused = true }
        .onChange(of: isFocused) { _, focused in capture.isEditingText = focused }
        .onDisappear { capture.isEditingText = false }
    }

    private var millimetres: Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value > 0 else { return nil }
        return value
    }

    private func go() {
        guard let millimetres else { return }
        positions.go(toMillimetres: millimetres, on: camera)
        done()
    }
}
