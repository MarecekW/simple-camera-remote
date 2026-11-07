import AppKit
import CaptureCore
import Foundation
import Observation
import SonyProtocol
import SonyRemote

/// Named presets of the whole setup — exposure, white balance, focus, image
/// quality, the AF point and the live view's layout — saved as files and
/// recalled in one go.  The lens position isn't part of them: the A6700
/// can't be sent to an absolute zoom or focus position.
@MainActor
@Observable
final class PresetModel {
    /// What the naming sheet is for.
    enum Naming: Identifiable {
        case saveNew
        case rename(String)

        var id: String {
            switch self {
            case .saveNew: "new"
            case .rename(let name): "rename:" + name
            }
        }
    }

    private(set) var presets: [Preset] = []
    /// The preset last recalled or saved, which the header shows.
    private(set) var currentName: String? {
        didSet { UserDefaults.standard.set(currentName, forKey: Self.currentNameKey) }
    }
    private(set) var isApplying = false
    /// Shows the naming sheet while set.
    var naming: Naming?
    /// Asks before deleting while set.
    var pendingDeletion: String?

    @ObservationIgnored private let library: PresetLibrary
    @ObservationIgnored private let messages: MessageLog
    @ObservationIgnored private var reportedUnreadable: Set<String> = []

    private static let currentNameKey = "camera-remote.presets.current.v1"

    /// The camera settings a preset keeps, in the order they're applied:
    /// the exposure mode before the values it owns, white balance before
    /// kelvin, the focus mode before the area.
    static let cameraSettings: [(code: SonyPropertyCode, name: String)] = [
        (.exposureProgramMode, "Exposure mode"), (.fNumber, "Aperture"), (.shutterSpeed, "Shutter"),
        (.isoSensitivity, "ISO"), (.exposureCompensation, "EV comp"), (.whiteBalance, "White balance"),
        (.colorTemperature, "Kelvin"), (.dynamicRangeOptimizer, "DRO"),
        (.lensCompensationShading, "Shading compensation"),
        (.lensCompensationChromaticAberration, "Chromatic aberration compensation"),
        (.lensCompensationDistortion, "Distortion compensation"), (.imageSize, "Image size"),
        (.aspectRatio, "Aspect ratio"), (.jpegQuality, "JPEG quality"), (.rawCompression, "RAW compression"),
        (.focusMode, "Focus mode"), (.focusArea, "Focus area"),
    ]
    private static let cameraSettingCodes = cameraSettings.map(\.code.rawValue)

    init(
        messages: MessageLog,
        folder: URL = AppInfo.supportDirectory.appending(path: "Presets", directoryHint: .isDirectory)
    ) {
        self.messages = messages
        library = PresetLibrary(folder: folder)
        currentName = UserDefaults.standard.string(forKey: Self.currentNameKey)
        reload()
        // Presets copied into the folder by hand show up on coming back.
        // The model lives as long as the app, so the observer is never removed.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    var current: Preset? {
        presets.first { $0.name == currentName }
    }

    /// Reads the folder again, picking up presets copied in by hand.
    func reload() {
        let loaded = library.load()
        presets = loaded.presets
        if let currentName, !presets.contains(where: { $0.name == currentName }) { self.currentName = nil }
        // Each unreadable file is reported once, not on every reload.
        for file in loaded.unreadable where !reportedUnreadable.contains(file) {
            messages.post(.warning, "The preset file \(file) can't be read.")
        }
        reportedUnreadable = Set(loaded.unreadable)
    }

    // MARK: - Recall

    /// Whether the camera or the live view has moved away from the current
    /// preset since it was recalled or saved.  The AF point isn't compared:
    /// the camera only shows it while it draws the frame.
    func isModified(camera: SonyCamera, liveView: LiveViewModel) -> Bool {
        guard let current else { return false }
        if liveView.presetView != current.view { return true }
        return current.settings(limitedTo: Self.cameraSettingCodes).recalled.contains { setting in
            camera.properties[SonyPropertyCode(rawValue: setting.code)]?.currentValue != PTPValue(setting.value)
        }
    }

    /// Applies `preset`: gives the app the exposure (taking the camera's
    /// dials), sets the camera in order, moves the AF point and lays out
    /// the live view.  Whatever couldn't be applied is reported by name.
    func apply(
        _ preset: Preset, cameraModel: CameraModel, camera: SonyCamera, liveView: LiveViewModel,
        controls: CameraControls
    ) async {
        guard !isApplying else { return }
        guard !controls.isExposureLocked else {
            messages.post(.warning, "Unlock the exposure to recall a preset.")
            return
        }
        isApplying = true
        defer { isApplying = false }
        var problems: [String] = []
        if preset.camera != camera.name {
            problems.append("saved with \(preset.camera)")
        }
        // Only the settings a preset keeps are ever sent, whatever the file
        // says.
        let (kept, ignored) = preset.settings(limitedTo: Self.cameraSettingCodes)
        problems += ignored.map { String(format: "0x%04X not a preset setting", $0) }
        // Nor values the app doesn't offer, e.g. a movie exposure mode.
        let isOffered = { (setting: Preset.CameraSetting) in
            CameraSettingFormat.isOffered(PTPValue(setting.value), of: SonyPropertyCode(rawValue: setting.code))
        }
        let recalled = kept.filter(isOffered)
        problems += kept.filter { !isOffered($0) }.map {
            Self.describe(SonyPropertyCode(rawValue: $0.code), .notOffered)
        }
        do {
            // A preset sets the exposure, so the app has to own it.
            try await cameraModel.takeExposure(on: camera)
            let skipped = try await camera.apply(
                recalled.map { (SonyPropertyCode(rawValue: $0.code), PTPValue($0.value)) })
            problems += skipped.map { Self.describe($0.code, $0.skip) }
            if let point = preset.afPoint, camera.isAutofocusing, camera.hasMovableAFFrame {
                try await camera.moveAFPoint(to: LiveViewPoint(x: point.x, y: point.y))
            }
        } catch {
            messages.post(.failure, "The camera didn't take preset “\(preset.name)”.")
            Log.ptp.error("applying a preset failed: \(String(describing: error), privacy: .public)")
            return
        }
        if await !liveView.apply(preset.view) {
            problems.append("overlay image missing")
        }
        currentName = preset.name
        if problems.isEmpty {
            messages.post(.success, "Recalled “\(preset.name)”.")
        } else {
            messages.post(.warning, "Recalled “\(preset.name)” except: \(problems.joined(separator: "; ")).")
        }
    }

    private static func describe(_ code: SonyPropertyCode, _ skip: SonyCamera.SettingSkip) -> String {
        let name = cameraSettings.first { $0.code == code }?.name ?? "\(code)"
        return switch skip {
        case .notOffered: "\(name) not offered"
        case .notAccepted: "\(name) not settable now"
        case .notApplied: "\(name) not taken"
        }
    }

    // MARK: - Saving

    func problem(withName name: String, renaming oldName: String? = nil) -> String? {
        let others = presets.map(\.name).filter { $0 != oldName }
        return switch PresetLibrary.problem(with: name, existing: others) {
        case .empty: "Give the preset a name."
        case .invalidCharacters: "A name can't start with a dot or contain / or :."
        case .taken: "A preset with this name already exists."
        case nil: nil
        }
    }

    /// Saves the current setup as a new preset called `name`.
    func saveNew(named name: String, camera: SonyCamera, liveView: LiveViewModel) {
        let name = PresetLibrary.trimmed(name)
        write(Self.snapshot(named: name, camera: camera, liveView: liveView, previous: nil))
    }

    /// Replaces the current preset with the current setup.
    func updateCurrent(camera: SonyCamera, liveView: LiveViewModel) {
        guard let current else { return }
        write(Self.snapshot(named: current.name, camera: camera, liveView: liveView, previous: current))
    }

    func rename(_ oldName: String, to newName: String) {
        let newName = PresetLibrary.trimmed(newName)
        do {
            try library.rename(oldName, to: newName)
        } catch {
            messages.post(.failure, "Couldn't rename “\(oldName)”: \(error.localizedDescription)")
            return
        }
        if currentName == oldName { currentName = newName }
        reload()
    }

    /// Moves the preset's file to the Trash, so a mistake can be undone.
    func delete(named name: String) {
        do {
            try FileManager.default.trashItem(at: library.file(for: name), resultingItemURL: nil)
        } catch {
            messages.post(.failure, "Couldn't delete “\(name)”: \(error.localizedDescription)")
            return
        }
        reload()
        messages.post(.info, "Deleted preset “\(name)”.")
    }

    func showInFinder() {
        try? FileManager.default.createDirectory(at: library.folder, withIntermediateDirectories: true)
        if let current {
            NSWorkspace.shared.activateFileViewerSelecting([library.file(for: current.name)])
        } else {
            NSWorkspace.shared.open(library.folder)
        }
    }

    private func write(_ preset: Preset) {
        do {
            try library.save(preset)
        } catch {
            messages.post(.failure, "Couldn't save preset “\(preset.name)”: \(error.localizedDescription)")
            return
        }
        currentName = preset.name
        reload()
        messages.post(.success, "Saved preset “\(preset.name)”.")
    }

    /// The current setup.  Only settings the user could change are kept —
    /// not those the exposure mode owns (they'd only fail on recall) — but
    /// always the exposure mode, which the app can set once it owns the
    /// exposure.  Kelvin only while white balance is set in kelvin.  The AF
    /// point is read from the frame the live view shows; when it shows none
    /// (magnified, or the camera not drawing it), `previous`'s is kept.
    private static func snapshot(
        named name: String, camera: SonyCamera, liveView: LiveViewModel, previous: Preset?
    ) -> Preset {
        let isKelvin =
            camera.properties[.whiteBalance]?.currentValue
            == .unsigned(WhiteBalanceMode.colorTemperature.rawValue)
        let settings = cameraSettings.compactMap { code, _ -> Preset.CameraSetting? in
            guard let descriptor = camera.properties[code], let value = Preset.Value(descriptor.currentValue),
                code == .exposureProgramMode || (descriptor.isWritable && descriptor.availability == .enabled),
                code != .colorTemperature || isKelvin
            else { return nil }
            return Preset.CameraSetting(
                code: code.rawValue, value: value,
                display: CameraSettingFormat.display(descriptor.currentValue, of: code))
        }
        // Magnified, the live view's frames are on the magnified crop.
        let afFrame =
            camera.hasMovableAFFrame && camera.magnification == nil
            ? liveView.cameraFrames.first { $0.kind == .focus } : nil
        return Preset(
            name: name, camera: camera.name, savedAt: .now, settings: settings,
            afPoint: afFrame.map { Preset.Point(x: $0.centre.x, y: $0.centre.y) } ?? previous?.afPoint,
            view: liveView.presetView)
    }
}

extension PTPValue {
    init(_ value: Preset.Value) {
        switch value {
        case .signed(let number): self = .signed(number)
        case .unsigned(let number): self = .unsigned(number)
        }
    }
}

extension Preset.Value {
    /// Nil for strings, which no preset setting is.
    init?(_ value: PTPValue) {
        switch value {
        case .signed(let number): self = .signed(number)
        case .unsigned(let number): self = .unsigned(number)
        case .string: return nil
        }
    }
}
