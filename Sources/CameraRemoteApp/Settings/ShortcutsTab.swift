import AppKit
import SwiftUI

/// Keys for the main actions, recorded by pressing them — e.g. on a
/// wireless numpad — and the app's fixed single-key shortcuts for
/// reference.
struct ShortcutsTab: View {
    @Bindable var bindings: ShortcutBindings

    var body: some View {
        SettingsNote(
            "Click a key's box, then press a single key, without ⌘ ⌥ ⌃ ⇧ (Esc cancels). On a numpad, Num Lock "
                + "changes what the number keys send, so set them with Num Lock as you'll use it; + − * / are the "
                + "same either way. Your keys work whenever the app is in front and you're not typing in a text field.")
        HStack {
            Button("Restore Defaults") { bindings.restoreDefaults() }
                .buttonStyle(ChipButtonStyle())
            Spacer()
        }
        SettingsGroup("Your keys: shooting") {
            recorders(ShortcutBindings.Action.allCases.filter { !$0.isLiveViewOption })
        }
        SettingsGroup("Your keys: live view") {
            recorders(ShortcutBindings.Action.allCases.filter(\.isLiveViewOption))
        }
        SettingsGroup("Built in") {
            ForEach(Self.builtIn, id: \.keys) { shortcut in
                SettingsRow(shortcut.keys) {
                    Text(shortcut.action)
                }
            }
        }
    }

    private func recorders(_ actions: [ShortcutBindings.Action]) -> some View {
        ForEach(actions) { action in
            SettingsRow(action.title) {
                VStack(alignment: .leading, spacing: 4) {
                    KeyRecorder(bindings: bindings, action: action)
                    SettingsNote(action.detail)
                }
            }
        }
    }

    private static let builtIn: [(keys: String, action: String)] = [
        ("Space / ⌘K", "Shoot"),
        ("A (hold)", "Half press: autofocus while held"),
        ("W / T (hold)", "Zoom out / in; ⇧ for fast"),
        ("S F I E", "Step shutter, aperture, ISO, exposure comp.; ⇧ steps back"),
        ("[ ] or ⌘[ ⌘]", "Previous / next side (wood strip capture)"),
        ("M", "Focus magnifier"),
        ("R", "Review the last shot; while reviewing, Z switches Fit / 100 % and K shows clipping"),
        ("G C H P U O", "Grid, centre cross, histogram, peaking, rulers, overlay"),
        ("⌥1–3 / ⇧⌥1–3", "Recall / save a zoom position"),
        ("⌘N", "Next load (wood strip capture)"),
        ("⌘1–⌘9", "Recall a preset"),
        ("⌥⌘L", "Lock exposure"),
        ("⌘R", "Reconnect"),
    ]
}

/// The key bound to an action: click, then press a key to change it.
private struct KeyRecorder: View {
    let bindings: ShortcutBindings
    let action: ShortcutBindings.Action

    @State private var monitor: Any?
    /// Ends recording when Settings stops being the key window.
    @State private var resignObserver: NSObjectProtocol?
    @State private var refusal: String?

    private var isRecording: Bool { bindings.recordingAction == action }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(isRecording ? "Press a key…" : bindings.keys[action]?.name ?? "None")
                    .foregroundStyle(
                        isRecording || bindings.keys[action] == nil ? Theme.textSecondary : Theme.textPrimary
                    )
                    .frame(width: 140)
                    .panelBox(fill: Theme.background)
                    .overlay(
                        RoundedRectangle(cornerRadius: Layout.cornerRadius)
                            .strokeBorder(isRecording ? Theme.focus : .clear, lineWidth: 1.5)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(action.title) key")
            .accessibilityValue(bindings.keys[action]?.name ?? "none")
            if bindings.keys[action] != nil, !isRecording {
                Button {
                    bindings.clear(action)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Remove the key")
                .accessibilityLabel("Remove the \(action.title) key")
            }
            if let refusal {
                Text(refusal).font(.caption).foregroundStyle(Theme.warning)
            }
        }
        // Another recorder started, or the tab closed: stop listening.
        .onChange(of: bindings.recordingAction) { _, recording in
            if recording != action { removeMonitor() }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        refusal = nil
        bindings.recordingAction = action
        removeMonitor()
        // Only keys pressed in Settings are recorded; ⌘ shortcuts (⌘W, ⌘Q)
        // still work.
        let window = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === window, !event.modifierFlags.contains(.command) else { return event }
            MainActor.assumeIsolated { record(event) }
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { stopRecording() }
        }
    }

    private func record(_ event: NSEvent) {
        guard event.keyCode != ShortcutBindings.KeyCodes.escape else {
            stopRecording()
            return
        }
        guard event.modifierFlags.intersection([.control, .option, .shift]).isEmpty else {
            refusal = "Press the key alone."
            return
        }
        guard let key = ShortcutBindings.key(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
        else {
            refusal = "The app already uses that key."
            return
        }
        refusal = nil
        bindings.bind(key, to: action)
        stopRecording()
    }

    private func stopRecording() {
        removeMonitor()
        if isRecording { bindings.recordingAction = nil }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}
