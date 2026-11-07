import CaptureCore
import SonyRemote
import SwiftUI

/// The Camera menu: shooting and lens commands with their shortcuts, so they
/// can be found without docs.  Single-key shortcuts (zoom, exposure steps,
/// keys bound in Settings) are listed in the tooltips and Settings →
/// Shortcuts, and handled by `KeyboardShortcuts`.
struct CameraCommands: Commands {
    let camera: CameraModel
    let capture: CaptureModel
    @Bindable var controls: CameraControls
    let zoomPositions: ZoomPositions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Next Load") { capture.startNextLoad() }
                .keyboardShortcut("n")
                .disabled(capture.session.sample == nil || capture.isCapturing)
        }
        CommandMenu("Camera") {
            Button("Shoot") { Task { await capture.shoot() } }
                .keyboardShortcut("k")
                .disabled(capture.blockedReason != nil)
            Divider()
            Button("Next Side") { step(side: 1) }
                .keyboardShortcut("]")
                .disabled(capture.session.sample == nil || capture.isCapturing)
            Button("Previous Side") { step(side: -1) }
                .keyboardShortcut("[")
                .disabled(capture.session.sample == nil || capture.isCapturing)
            Divider()
            ForEach(ZoomPositions.slots, id: \.self) { slot in
                Button(positionTitle(slot)) {
                    if let sonyCamera = connectedCamera { zoomPositions.recall(slot, on: sonyCamera) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(slot)")), modifiers: .option)
                .disabled(connectedCamera == nil || zoomPositions.saved[slot] == nil)
            }
            Menu("Save Zoom Position") {
                ForEach(ZoomPositions.slots, id: \.self) { slot in
                    Button("Position \(slot)") {
                        if let sonyCamera = connectedCamera { zoomPositions.save(slot, on: sonyCamera) }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(slot)")), modifiers: [.option, .shift])
                }
            }
            .disabled(connectedCamera == nil)
            Divider()
            Toggle("Lock Exposure", isOn: $controls.isExposureLocked)
                .keyboardShortcut("l", modifiers: [.option, .command])
            Picker("Exposure Set By", selection: Bindable(camera).exposureControl) {
                Text("App (Camera Dials Locked)").tag(CameraModel.ExposureControl.app)
                Text("Camera Dials").tag(CameraModel.ExposureControl.cameraDials)
            }
            .disabled(capture.isCapturing)
            Divider()
            // Not mid-capture or while a connection is being made.
            Button("Reconnect") { camera.reconnect() }
                .keyboardShortcut("r")
                .disabled(capture.isCapturing || camera.state == .connecting)
        }
    }

    private var connectedCamera: SonyCamera? {
        camera.state == .connected ? camera.camera : nil
    }

    private func positionTitle(_ slot: UInt8) -> String {
        guard let position = zoomPositions.saved[slot] else { return "Zoom Position \(slot)" }
        return "Zoom Position \(slot) (\(FocalLength(rawValue: position.focalLength)))"
    }

    private func step(side offset: Int) {
        guard let side = capture.session.sample?.side else { return }
        capture.setSide(side + offset)
    }
}
