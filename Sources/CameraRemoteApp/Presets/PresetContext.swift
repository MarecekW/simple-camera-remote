import CaptureCore
import SonyRemote

/// Everything a preset recall or save needs, passed as one.
@MainActor
struct PresetContext {
    let presets: PresetModel
    let cameraModel: CameraModel
    let liveView: LiveViewModel
    let controls: CameraControls
    let capture: CaptureModel

    /// The connected camera, if any.
    var camera: SonyCamera? {
        cameraModel.state == .connected ? cameraModel.camera : nil
    }

    var canRecall: Bool {
        camera != nil && !presets.isApplying && !capture.isCapturing
    }

    /// Saving mid-recall would keep a half-applied setup.
    var canSave: Bool {
        camera != nil && !presets.isApplying
    }

    func recall(_ preset: Preset) {
        guard let camera else { return }
        Task {
            await presets.apply(
                preset, cameraModel: cameraModel, camera: camera, liveView: liveView, controls: controls)
        }
    }

    func updateCurrent() {
        guard let camera else { return }
        presets.updateCurrent(camera: camera, liveView: liveView)
    }
}
