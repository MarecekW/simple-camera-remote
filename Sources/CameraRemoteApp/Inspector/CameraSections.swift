import CaptureCore
import SonyProtocol
import SonyRemote
import SwiftUI

/// Mode, aperture, shutter, ISO and compensation — set once per setup, so
/// usually collapsed to its summary.
struct ExposureSection: View {
    let camera: SonyCamera
    @Bindable var controls: CameraControls
    @Bindable var cameraModel: CameraModel
    let advisories: [Advisory]

    private static let advisedSettings: Set<CaptureRecord.Setting> = [
        .exposureMode, .aperture, .shutterSpeed, .iso, .exposureCompensation,
    ]

    private static let modes = [ExposureMode.programAuto, .aperturePriority, .shutterPriority, .manual]
        .map { PTPValue.unsigned($0.rawValue) }

    var body: some View {
        InspectorSection(
            "Exposure", id: "exposure", summary: summary,
            // The live view's exposure preview is judged here too.
            advisories: advisories.messages(for: Self.advisedSettings)
                + advisories.messages(of: .liveViewSettingEffectOff),
            expandedByDefault: false
        ) {
            InspectorRow("Set by") {
                PanelSegmented(
                    label: "Exposure set by", selection: $cameraModel.exposureControl,
                    options: [(.app, "App"), (.cameraDials, "Camera dials")]
                )
                .disabled(controls.isCapturing())
                .help(
                    "App: the camera's mode dial and wheels are locked while connected (given back when the app quits). "
                        + "Camera dials: set exposure on the camera; the app shows it.")
            }
            CameraSegmentedPicker(
                label: "Mode", code: .exposureProgramMode, camera: camera, controls: controls, values: Self.modes,
                fallback: ("Set M", .unsigned(ExposureMode.manual.rawValue)),
                advisory: advisories.message(for: .exposureMode))
            CameraValueStepper(
                label: "Aperture", code: .fNumber, camera: camera, controls: controls, shortcut: "F / ⇧F",
                advisory: advisories.message(for: .aperture))
            CameraValueStepper(
                label: "Shutter", code: .shutterSpeed, camera: camera, controls: controls, shortcut: "S / ⇧S",
                advisory: advisories.message(for: .shutterSpeed))
            CameraValueStepper(
                label: "ISO", code: .isoSensitivity, camera: camera, controls: controls, shortcut: "I / ⇧I",
                advisory: advisories.message(for: .iso))
            CameraValueStepper(
                label: "EV comp", code: .exposureCompensation, camera: camera, controls: controls,
                shortcut: "E / ⇧E", usesPlusMinus: true,
                advisory: advisories.message(for: .exposureCompensation))
        } menu: {
            Toggle("Lock Exposure", isOn: $controls.isExposureLocked)
            Button("Reset EV Compensation to 0") {
                controls.set(.exposureCompensation, to: .signed(0), on: camera)
            }
            .disabled(!controls.choices(for: .exposureCompensation, on: camera).contains(.signed(0)))
        }
    }

    /// Most important first; compensation only when it's set.
    private var summary: Text {
        let display = { (code: SonyPropertyCode) in
            controls.value(of: code, on: camera).map { CameraSettingFormat.display($0, of: code) } ?? "—"
        }
        var parts = [
            display(.exposureProgramMode), display(.shutterSpeed), display(.fNumber),
            "ISO " + display(.isoSensitivity),
        ]
        if let compensation = controls.value(of: .exposureCompensation, on: camera), compensation.integerValue != 0 {
            parts.append(CameraSettingFormat.display(compensation, of: .exposureCompensation))
        }
        let text = Text(parts.joined(separator: " · "))
        return controls.isExposureLocked ? Text("\(Image(systemName: "lock.fill")) ") + text : text
    }
}

/// White balance (with kelvin) and focus.
struct WhiteBalanceFocusSection: View {
    let camera: SonyCamera
    let controls: CameraControls
    let advisories: [Advisory]

    private static let focusModes = [FocusMode.singleAF, .continuousAF, .directManual, .manual]
        .map { PTPValue.unsigned($0.rawValue) }
    private static let colorTemperature = PTPValue.unsigned(WhiteBalanceMode.colorTemperature.rawValue)

    var body: some View {
        InspectorSection(
            "WB & Focus", id: "whiteBalanceFocus", summary: summary,
            advisories: advisories.messages(for: [.whiteBalance, .colorTemperature]), expandedByDefault: false
        ) {
            CameraPropertyRow(
                label: "Balance", code: .whiteBalance, camera: camera, controls: controls,
                advisory: advisories.message(for: .whiteBalance))
            kelvinRow
            CameraSegmentedPicker(
                label: "Focus", code: .focusMode, camera: camera, controls: controls, values: Self.focusModes)
            CameraPropertyRow(label: "Area", code: .focusArea, camera: camera, controls: controls)
            // Always there, so nothing moves; usable in MF and DMF.
            ManualFocusRow(camera: camera, controls: controls)
                .disabled(!isManuallyFocusable)
        }
    }

    /// MF, or DMF's manual touch-up after AF.
    private var isManuallyFocusable: Bool {
        let mode = controls.value(of: .focusMode, on: camera)
        return mode == .unsigned(FocusMode.manual.rawValue) || mode == .unsigned(FocusMode.directManual.rawValue)
    }

    /// Always present, so nothing moves: a stepper while white balance is in
    /// kelvin, else a button to switch to it.
    @ViewBuilder
    private var kelvinRow: some View {
        if controls.value(of: .whiteBalance, on: camera) == Self.colorTemperature {
            CameraValueStepper(
                label: "Kelvin", code: .colorTemperature, camera: camera, controls: controls,
                advisory: advisories.message(for: .colorTemperature))
        } else {
            InspectorRow("Kelvin") {
                Button {
                    controls.set(.whiteBalance, to: Self.colorTemperature, on: camera)
                } label: {
                    Text("Set in Kelvin").foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(PanelButtonStyle())
                .disabled(!controls.choices(for: .whiteBalance, on: camera).contains(Self.colorTemperature))
                .help("Fixed colour temperature — best for continuous lights and a ColorChecker")
            }
        }
    }

    private var summary: Text {
        let whiteBalance = controls.value(of: .whiteBalance, on: camera)
        let whiteBalanceText =
            whiteBalance == Self.colorTemperature
            ? controls.value(of: .colorTemperature, on: camera).map {
                CameraSettingFormat.display($0, of: .colorTemperature)
            } ?? "—"
            : whiteBalance.map { CameraSettingFormat.display($0, of: .whiteBalance) } ?? "—"
        let focus = controls.value(of: .focusMode, on: camera).map { CameraSettingFormat.display($0, of: .focusMode) }
        return Text([whiteBalanceText, focus ?? "—"].joined(separator: " · "))
    }
}

/// Manual focus in small, medium and large steps, nearer on the left and
/// farther on the right, as in Sony Remote; holding a button repeats.
private struct ManualFocusRow: View {
    let camera: SonyCamera
    let controls: CameraControls

    /// The camera's steps, smallest first, with their names.
    private static let steps = Array(zip(SonyCamera.manualFocusSteps, ["small", "medium", "large"]))

    var body: some View {
        InspectorRow("MF") {
            HStack(spacing: Layout.cellGap) {
                ForEach(Self.steps.reversed(), id: \.0) { step, name in
                    stepButton(-step, name: name, chevrons: Self.chevrons(for: step))
                }
                ForEach(Self.steps, id: \.0) { step, name in
                    stepButton(step, name: name, chevrons: Self.chevrons(for: step))
                }
            }
        }
        .help("Manual focus: nearer on the left, farther on the right (MF and DMF)")
    }

    /// One chevron for the small step, two for medium, three for large.
    private static func chevrons(for step: Int16) -> Int {
        (steps.firstIndex { $0.0 == step } ?? 0) + 1
    }

    private func stepButton(_ step: Int16, name: String, chevrons: Int) -> some View {
        let description = "\(step < 0 ? "Nearer" : "Farther"), \(name) step"
        return Button {
            controls.stepFocus(step, on: camera)
        } label: {
            HStack(spacing: -3) {
                ForEach(0..<chevrons, id: \.self) { _ in
                    Image(systemName: step < 0 ? "chevron.left" : "chevron.right")
                }
            }
            .font(.system(size: 9, weight: .bold))
        }
        .buttonStyle(PanelButtonStyle())
        .buttonRepeatBehavior(.enabled)
        .help(description + " — hold to repeat")
        .accessibilityLabel(description)
    }
}

/// What the camera records: format, quality, size, and in-camera processing
/// — needed once per setup, so collapsed with a check that the dataset
/// settings are right.
struct ImageSection: View {
    let camera: SonyCamera
    let controls: CameraControls
    let advisories: [Advisory]

    private static let advisedSettings: Set<CaptureRecord.Setting> = [
        .jpegQuality, .imageSize, .aspectRatio, .rawCompression, .dynamicRangeOptimizer,
        .lensCompensationShading, .lensCompensationChromaticAberration, .lensCompensationDistortion,
    ]

    private static let formats = [FileFormat.raw, .rawAndJPEG, .jpeg].map { PTPValue.unsigned($0.rawValue) }
    private static let lensCompensations: [(label: String, code: SonyPropertyCode)] = [
        ("Shading", .lensCompensationShading),
        ("Chromatic aberration", .lensCompensationChromaticAberration),
        ("Distortion", .lensCompensationDistortion),
    ]

    var body: some View {
        InspectorSection(
            "Image", id: "image", summary: summary,
            advisories: advisories.messages(for: Self.advisedSettings), expandedByDefault: false
        ) {
            CameraSegmentedPicker(
                label: "Format", code: .fileFormat, camera: camera, controls: controls, values: Self.formats)
            CameraPropertyRow(
                label: "JPEG", code: .jpegQuality, camera: camera, controls: controls,
                advisory: advisories.message(for: .jpegQuality))
            CameraPropertyRow(
                label: "Size", code: .imageSize, camera: camera, controls: controls,
                advisory: advisories.message(for: .imageSize))
            CameraPropertyRow(
                label: "Aspect", code: .aspectRatio, camera: camera, controls: controls,
                advisory: advisories.message(for: .aspectRatio))
            CameraPropertyRow(
                label: "RAW", code: .rawCompression, camera: camera, controls: controls,
                advisory: advisories.message(for: .rawCompression))
            CameraPropertyRow(
                label: "DRO", code: .dynamicRangeOptimizer, camera: camera, controls: controls,
                advisory: advisories.message(for: .dynamicRangeOptimizer))
            InspectorRow("Lens", advisory: lensAdvisory) {
                PanelMenu(title: lensCompensationSummary) {
                    ForEach(Self.lensCompensations, id: \.code) { item in
                        Toggle(item.label, isOn: lensCompensationBinding(item.code))
                            .disabled(
                                !controls.choices(for: item.code, on: camera).contains(
                                    lensCompensationToggled(item.code)))
                    }
                }
                .help("In-camera lens corrections apply to the JPEG only; RAW is corrected later.")
            }
        }
    }

    private var lensAdvisory: String? {
        let messages = advisories.messages(
            for: [.lensCompensationShading, .lensCompensationChromaticAberration, .lensCompensationDistortion])
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private static let compensationOff = PTPValue.unsigned(1)
    private static let compensationAuto = PTPValue.unsigned(2)

    private func isLensCompensationOn(_ code: SonyPropertyCode) -> Bool {
        controls.value(of: code, on: camera).map { $0 != Self.compensationOff } ?? false
    }

    /// The value a click on `code`'s toggle sends — the one the camera has
    /// to offer for the toggle to be enabled.
    private func lensCompensationToggled(_ code: SonyPropertyCode) -> PTPValue {
        isLensCompensationOn(code) ? Self.compensationOff : Self.compensationAuto
    }

    private func lensCompensationBinding(_ code: SonyPropertyCode) -> Binding<Bool> {
        Binding(
            get: { isLensCompensationOn(code) },
            set: { controls.set(code, to: $0 ? Self.compensationAuto : Self.compensationOff, on: camera) })
    }

    private var lensCompensationSummary: String {
        let on = Self.lensCompensations.count { isLensCompensationOn($0.code) }
        switch on {
        case 0: return "Corrections off"
        case Self.lensCompensations.count: return "All corrections on"
        default: return "\(on) of \(Self.lensCompensations.count) corrections on"
        }
    }

    /// The key values and whether they suit the dataset.
    private var summary: Text {
        let values = [SonyPropertyCode.fileFormat, .imageSize, .aspectRatio].map { code in
            controls.value(of: code, on: camera).map { CameraSettingFormat.display($0, of: code) } ?? "—"
        }
        let check =
            CaptureSettings.issues(in: camera.properties).isEmpty
            ? Text(Image(systemName: "checkmark"))
            : Text(Image(systemName: "exclamationmark.triangle.fill")).foregroundStyle(Theme.warning)
        return Text(values.joined(separator: " · ") + "  ") + check
    }
}
