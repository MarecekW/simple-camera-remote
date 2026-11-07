import CaptureCore
import SonyProtocol
import SonyRemote
import SwiftUI

/// The strip across the top: which camera, how it's connected, the things
/// that stop a session — battery and card space — and the presets.
struct StatusBar: View {
    let model: CameraModel
    let presets: PresetContext
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 16) {
            connection
            if let camera = model.camera, model.state == .connected {
                Divider().frame(height: 16)
                CameraFacts(camera: camera)
            }
            Spacer()
            // Close to the gear: both set the app up, apart from the facts.
            HStack(spacing: 4) {
                PresetButton(context: presets)
                settingsButton
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Layout.statusBarHeight)
        // A lost camera has to be impossible to miss.
        .background(isFailed ? Theme.failure.opacity(0.35) : Theme.panel)
        .overlay(alignment: .bottom) { Theme.divider.frame(height: 1) }
    }

    private var settingsButton: some View {
        Button {
            openSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    // A newer release: the details are in Settings → About.
                    if UpdateChecker.shared.availableUpdate != nil {
                        Circle()
                            .fill(Theme.failure)
                            .frame(width: 6, height: 6)
                            .offset(x: -5, y: 6)
                            .allowsHitTesting(false)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(UpdateChecker.shared.availableUpdate == nil ? "Settings (⌘,)" : "Settings (⌘,) — an update is available")
        .accessibilityLabel("Settings")
    }

    private var connection: some View {
        HStack(spacing: 6) {
            Circle().fill(indicatorColor).frame(width: 8, height: 8)
            Text(model.camera?.name ?? "No camera")
                .foregroundStyle(Theme.textPrimary)
            Text(stateLabel)
                .foregroundStyle(Theme.textSecondary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private var isFailed: Bool {
        if case .failed = model.state { return true }
        return false
    }

    private var indicatorColor: Color {
        switch model.state {
        case .noCamera: Theme.textSecondary
        case .connecting: Theme.warning
        case .connected: Theme.success
        case .failed: Theme.failure
        }
    }

    private var stateLabel: String {
        switch model.state {
        case .noCamera: "Connect the camera over USB"
        case .connecting: "Connecting…"
        case .connected: "USB"
        case .failed: "Disconnected"
        }
    }
}

/// Battery, card and lens, read from the camera's properties.
private struct CameraFacts: View {
    let camera: SonyCamera

    var body: some View {
        HStack(spacing: 16) {
            if let percent = camera.properties[.batteryRemaining]?.currentValue.integerValue, percent >= 0 {
                Label("\(percent) %", systemImage: Self.batterySymbol(percent: percent, onUSBPower: onUSBPower))
                    .accessibilityLabel("Battery \(percent) percent\(onUSBPower ? ", powered over USB" : "")")
            }
            if let shots = camera.properties[.mediaSlot1RemainingShots]?.currentValue.integerValue {
                Label("\(shots) left", systemImage: "sdcard")
                    .help("Shots left on the card")
                    .accessibilityLabel("\(shots) shots left on the card")
            }
            if let lens = camera.lensName {
                Label(lens, systemImage: "camera.aperture")
            }
            if let raw = camera.properties[.focalLength]?.currentValue.bitPattern {
                let focalLength = FocalLength(rawValue: UInt32(truncatingIfNeeded: raw))
                Text(focalLength.description)
                    .accessibilityLabel("Focal length \(focalLength.description)")
            }
        }
        .font(.callout)
        .foregroundStyle(Theme.textSecondary)
        .labelStyle(.titleAndIcon)
    }

    /// The camera's "USB Power Supply" setting (on = 2): tethered over USB,
    /// that means it runs on USB power, as its own display shows.
    private var onUSBPower: Bool {
        camera.properties[.usbPowerSupply]?.currentValue == .unsigned(2)
    }

    private static func batterySymbol(percent: Int64, onUSBPower: Bool) -> String {
        if onUSBPower { return "battery.100percent.bolt" }
        return switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}
