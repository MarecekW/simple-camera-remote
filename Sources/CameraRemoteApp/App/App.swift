import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the window appears; consulted when quitting.
    var capture: CaptureModel?
    /// Set with `capture`; its dials are handed back when quitting.
    var camera: CameraModel?

    override init() {
        // A bare Swift Package executable has no bundle name, so AppKit would
        // title the menu bar "camera-remote-app"; set the real name before
        // NSApp builds it.
        ProcessInfo.processInfo.processName = "Simple Camera Remote"
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dark AppKit controls (menus, pickers) to match the SwiftUI views.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // A bare executable has no bundle .icns, so the Dock would show the
        // generic one; the art comes from scripts/make-icon.swift.
        if !AppInfo.isAssembledApp, let icon = AppInfo.icon { NSApp.applicationIconImage = icon }
        // A bare executable started from a terminal isn't a regular app until
        // told so: without this its window looks active but keystrokes go to
        // the terminal.  Harmless in the assembled .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        UpdateChecker.shared.startPeriodicChecks()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A capture still transferring or saving finishes first: quitting
    /// mid-transfer would leave its files only on the card.  Then the
    /// camera's dials are handed back, so the camera works on its own again.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard capture?.isCapturing == true || camera?.state == .connected else { return .terminateNow }
        Task {
            await capture?.waitUntilIdle()
            await camera?.handBackDials()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct CameraRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var camera: CameraModel
    @State private var settings: AppSettings
    @State private var capture: CaptureModel
    @State private var liveView: LiveViewModel
    @State private var messages: MessageLog
    @State private var controls: CameraControls
    @State private var zoomPositions: ZoomPositions
    @State private var keyboardShortcuts: KeyboardShortcuts
    @State private var review: ReviewModel
    @State private var shortcutBindings: ShortcutBindings
    @State private var presets: PresetModel

    init() {
        let messages = MessageLog()
        let camera = CameraModel(messages: messages)
        let settings = AppSettings()
        let capture = CaptureModel(camera: camera, settings: settings, messages: messages)
        let controls = CameraControls(messages: messages)
        controls.isCapturing = { capture.isCapturing }
        _camera = State(initialValue: camera)
        _settings = State(initialValue: settings)
        _messages = State(initialValue: messages)
        _capture = State(initialValue: capture)
        _controls = State(initialValue: controls)
        _zoomPositions = State(initialValue: ZoomPositions(messages: messages))
        let presets = PresetModel(messages: messages)
        capture.isShutterInUse = { controls.isUsingShutter }
        capture.isRecallingPreset = { presets.isApplying }
        _presets = State(initialValue: presets)
        let review = ReviewModel()
        let liveView = LiveViewModel()
        _liveView = State(initialValue: liveView)
        let shortcutBindings = ShortcutBindings()
        _review = State(initialValue: review)
        _shortcutBindings = State(initialValue: shortcutBindings)
        _keyboardShortcuts = State(
            initialValue: KeyboardShortcuts(
                camera: camera, capture: capture, controls: controls, bindings: shortcutBindings, review: review,
                liveView: liveView, messages: messages))
    }

    var body: some Scene {
        Window("Simple Camera Remote", id: "main") {
            ContentView(
                camera: camera, liveView: liveView, capture: capture, settings: settings, messages: messages,
                controls: controls, zoomPositions: zoomPositions, review: review, presets: presetContext
            )
            .frame(minWidth: Layout.minimumWindowSize.width, minHeight: Layout.minimumWindowSize.height)
            .onAppear {
                appDelegate.capture = capture
                appDelegate.camera = camera
                keyboardShortcuts.install()
            }
        }
        .commands {
            CameraCommands(camera: camera, capture: capture, controls: controls, zoomPositions: zoomPositions)
            CommandMenu("Presets") {
                PresetMenuItems(context: presetContext, showsShortcuts: true)
            }
        }
        Settings {
            SettingsView(settings: settings, shortcuts: shortcutBindings)
        }
    }

    private var presetContext: PresetContext {
        PresetContext(
            presets: presets, cameraModel: camera, liveView: liveView, controls: controls, capture: capture)
    }
}
