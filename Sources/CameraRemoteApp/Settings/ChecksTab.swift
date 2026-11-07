import SwiftUI

/// What the checks look for, the lights, and the scale estimate.
struct ChecksTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsGroup("Shooting type") {
            PanelPopUp(
                label: "Photos are for", selection: $settings.shootingType,
                options: [
                    (.dataset, "A dataset or scientific record"), (.product, "Products"), (.portrait, "Portraits"),
                    (.off, "Anything — no checks"),
                ])
            SettingsNote(shootingTypeDescription)
        }
        SettingsGroup("Lights") {
            SettingsRow("Mains frequency") {
                PanelSegmented(
                    label: "Mains frequency", selection: $settings.mainsFrequency,
                    options: [(50, "50 Hz"), (60, "60 Hz")])
            }
            SettingsNote(
                "50 Hz in Europe, Africa, Australia and most of Asia; 60 Hz in North America and parts of South "
                    + "America and Asia. Mains-powered lights flicker at twice this rate, and shutter speeds that "
                    + "don't span whole flicker cycles can show dark bands, so they get a warning.")
        }
        SettingsGroup("Scale estimate") {
            SettingsRow("Smallest feature") {
                NumberField(value: $settings.featureSize, unit: "mm")
            }
            SettingsRow("Pixels it needs") {
                NumberField(value: $settings.featureMinimumPixels, unit: "px in the full-resolution image")
            }
            SettingsNote(
                "The smallest detail you need to see, and how many pixels it should cover. The Scale section in "
                    + "the main window warns when the working distance gives it fewer.")
        }
    }

    private var shootingTypeDescription: String {
        switch settings.shootingType {
        case .dataset:
            "Every shot must match the others, at full quality: warnings for automatic exposure, ISO and "
                + "white balance, in-camera tone changes (DRO), banding under mains lights, reduced size or "
                + "quality, and any setting that changed since the session's first shot."
        case .product:
            "Consistent exposure and colour across a catalogue: warnings for automatic exposure, ISO and white "
                + "balance, and banding."
        case .portrait: "Settings change from shot to shot on purpose; only banding under mains lights is flagged."
        case .off: "Nothing is checked, shown or recorded."
        }
    }
}

/// A positive number in the panel style, applied when typing ends (Return
/// or leaving the field); anything else puts the current value back.
private struct NumberField: View {
    @Binding var value: Double
    let unit: String

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .monospacedDigit()
                .padding(.horizontal, Layout.valueInset)
                .panelBox(fill: Theme.background)
                .frame(width: 80)
                .focused($isFocused)
                .onSubmit(apply)
            Text(unit).foregroundStyle(Theme.textSecondary)
        }
        .onAppear { text = value.formatted() }
        .onChange(of: isFocused) { _, focused in if !focused { apply() } }
    }

    private func apply() {
        if let typed = try? Double(text, format: .number), typed > 0, typed.isFinite { value = typed }
        text = value.formatted()
    }
}
