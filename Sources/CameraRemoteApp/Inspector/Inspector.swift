import CaptureCore
import SonyRemote
import SwiftUI

/// The right-hand panel: the histogram on top, every control in collapsible
/// sections, and the shutter fixed at the bottom with what it will produce.
struct Inspector: View {
    let camera: SonyCamera
    let capture: CaptureModel
    let settings: AppSettings
    let liveView: LiveViewModel
    let controls: CameraControls
    let zoomPositions: ZoomPositions
    let cameraModel: CameraModel
    let review: ReviewModel

    private var advisories: [Advisory] {
        CameraSettingFormat.advisories(
            from: camera.properties, mainsFrequency: settings.mainsFrequency, shootingType: settings.shootingType,
            firstCapture: capture.firstCaptureSettings)
    }

    var body: some View {
        VStack(spacing: 0) {
            if liveView.showsHistogram {
                // A leaf view: the histogram changes every frame, and only
                // this view should redraw for it.
                HistogramPanel(liveView: liveView, review: review)
                    .frame(height: 76)
                    .padding(Layout.inspectorPadding)
                Theme.divider.frame(height: 1)
            }
            ScrollView {
                VStack(spacing: 0) {
                    SessionSection(capture: capture, settings: settings)
                    ZoomSection(
                        camera: camera, controls: controls, positions: zoomPositions, capture: capture,
                        advisories: advisories)
                    ScaleSection(camera: camera, settings: settings, capture: capture)
                    ExposureSection(
                        camera: camera, controls: controls, cameraModel: cameraModel, advisories: advisories)
                    WhiteBalanceFocusSection(camera: camera, controls: controls, advisories: advisories)
                    ImageSection(camera: camera, controls: controls, advisories: advisories)
                    OutputSection(settings: settings, capture: capture)
                }
            }
            .scrollIndicators(.automatic)
            ShootPanel(camera: camera, capture: capture, liveView: liveView, controls: controls)
        }
        .frame(width: Layout.inspectorWidth)
        .background(Theme.panel.onTapGesture(perform: endTextEditing))
        .overlay(alignment: .leading) { Theme.divider.frame(width: 1) }
    }
}
