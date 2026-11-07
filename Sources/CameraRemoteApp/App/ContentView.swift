import AppKit
import SwiftUI

/// The main window: the camera bar above, the live view with the inspector
/// on its right — or, until the camera is connected, how to connect it — and
/// the message bar below.
struct ContentView: View {
    let camera: CameraModel
    let liveView: LiveViewModel
    let capture: CaptureModel
    let settings: AppSettings
    let messages: MessageLog
    let controls: CameraControls
    let zoomPositions: ZoomPositions
    let review: ReviewModel
    let presets: PresetContext

    @AppStorage(WelcomeView.shownKey) private var welcomeShown = false

    var body: some View {
        VStack(spacing: 0) {
            StatusBar(model: camera, presets: presets)
            if let sonyCamera = camera.camera, camera.state == .connected {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        LiveViewToolbar(
                            liveView: liveView, camera: sonyCamera, controls: controls, review: review,
                            capture: capture)
                        if review.isShown {
                            ReviewPane(review: review)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            LiveViewPane(liveView: liveView) { point in
                                // A click also confirms a text field being edited.
                                endTextEditing()
                                guard let point else { return }
                                controls.liveViewClicked(at: point, frames: liveView.cameraFrames, on: sonyCamera)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            // Streams while this view is shown; SwiftUI cancels
                            // the stream when it disappears (e.g. for review)
                            // or the camera changes.
                            .task(id: ObjectIdentifier(sonyCamera)) {
                                await liveView.run(sonyCamera)
                            }
                        }
                    }
                    Inspector(
                        camera: sonyCamera, capture: capture, settings: settings, liveView: liveView,
                        controls: controls, zoomPositions: zoomPositions, cameraModel: camera, review: review)
                }
            } else {
                ConnectionView(model: camera)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            MessageBar(capture: capture, messages: messages)
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .presetDialogs(presets)
        // Review always shows the newest capture.
        .onChange(of: capture.lastCapture, initial: true) { _, last in review.capture = last }
        // A simple session opens as today's date; a mode change starts over.
        .task(id: settings.captureMode) { await capture.captureModeChanged() }
        .sheet(isPresented: Binding(get: { !welcomeShown }, set: { if !$0 { welcomeShown = true } })) {
            WelcomeView(settings: settings) { welcomeShown = true }
        }
    }
}

/// Clicking outside a text field confirms it, as in other Mac apps' panels:
/// macOS keeps the focus in the field otherwise.
@MainActor
func endTextEditing() {
    NSApp.keyWindow?.makeFirstResponder(nil)
}

/// What the main area shows while there's no connected camera: how to get one.
private struct ConnectionView: View {
    let model: CameraModel

    var body: some View {
        VStack(spacing: 12) {
            switch model.state {
            case .noCamera:
                Image(systemName: "cable.connector")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.textSecondary)
                Text("Connect the camera")
                    .font(.title2)
                Text("Turn the camera on, connect it over USB, and choose Remote Shoot (PC Remote) on the camera.")
                    .foregroundStyle(Theme.textSecondary)
                Text("If the camera doesn't ask, set Setup › USB › USB Connection Mode to PC Remote in its menu.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            case .connecting:
                ProgressView()
                Text("Connecting to \(model.camera?.name ?? "the camera")…")
            case .connected:
                // The live view replaces this view while connected.
                EmptyView()
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.warning)
                Text(message)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                // ⌘R is the Camera menu's Reconnect.
                Button("Reconnect") { model.reconnect() }
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(32)
    }
}
