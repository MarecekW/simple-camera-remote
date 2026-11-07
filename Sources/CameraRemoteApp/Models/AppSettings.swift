import CaptureCore
import Foundation
import Observation

/// How captures are organised, named and where they're saved; remembered
/// between launches.
@MainActor
@Observable
final class AppSettings {
    /// File naming outside the sample workflow.
    enum SimpleNaming: String, CaseIterable {
        /// Names built from the simple template, e.g. `Portraits_0003`.
        case template
        /// The camera's own names, e.g. `DSC01135.ARW`.
        case cameraNames
    }

    static let defaultGrades = ["A", "B", "C", "Rustic", "Waste"]

    var captureMode: CaptureMode {
        didSet { defaults.set(captureMode.rawValue, forKey: Keys.captureMode) }
    }
    var simpleNaming: SimpleNaming {
        didSet { defaults.set(simpleNaming.rawValue, forKey: Keys.simpleNaming) }
    }
    /// Session folders are created inside this folder.
    var rootFolder: URL {
        didSet { defaults.set(rootFolder.path, forKey: Keys.rootFolder) }
    }
    /// Always valid: `setTemplate` rejects bad patterns.
    private(set) var sampleTemplate: FileNameTemplate
    private(set) var simpleTemplate: FileNameTemplate
    var grades: [String] {
        didSet { defaults.set(grades, forKey: Keys.grades) }
    }
    /// The local mains frequency, for the anti-banding advisory: 50 Hz in
    /// Europe, 60 Hz in the Americas.
    var mainsFrequency: Int {
        didSet { defaults.set(mainsFrequency, forKey: Keys.mainsFrequency) }
    }
    /// The working distance for the scale estimate, in millimetres from the
    /// camera's sensor-plane mark to the subject; nil until entered.
    var scaleDistance: Double? {
        didSet { defaults.set(scaleDistance, forKey: Keys.scaleDistance) }
    }
    /// The smallest feature that must be detectable (e.g. a knot), mm.
    var featureSize: Double {
        didSet {
            // Only a real size means anything (and keeps the maths finite).
            guard featureSize > 0, featureSize.isFinite else {
                featureSize = oldValue
                return
            }
            defaults.set(featureSize, forKey: Keys.featureSize)
        }
    }
    /// The pixels that feature needs in the full-resolution image (the
    /// detector works on tiles of it, so nothing is scaled down).
    var featureMinimumPixels: Double {
        didSet {
            guard featureMinimumPixels > 0, featureMinimumPixels.isFinite else {
                featureMinimumPixels = oldValue
                return
            }
            defaults.set(featureMinimumPixels, forKey: Keys.featureMinimumPixels)
        }
    }
    /// Who's shooting, recorded with each capture; empty when not set.
    var operatorName: String {
        didSet { defaults.set(operatorName, forKey: Keys.operatorName) }
    }
    /// What the photos are for; decides which advisories show.
    var shootingType: Advisory.ShootingType {
        didSet { defaults.set(shootingType.rawValue, forKey: Keys.shootingType) }
    }

    /// A sound when a capture is saved or fails, for working away from the
    /// screen.
    var playsCaptureSounds: Bool {
        didSet { defaults.set(playsCaptureSounds, forKey: Keys.playsCaptureSounds) }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let captureMode = "camera-remote.capture.mode.v1"
        static let simpleNaming = "camera-remote.capture.simpleNaming.v1"
        static let rootFolder = "camera-remote.capture.rootFolder.v1"
        static let sampleTemplate = "camera-remote.capture.sampleTemplate.v1"
        static let simpleTemplate = "camera-remote.capture.simpleTemplate.v1"
        static let grades = "camera-remote.capture.grades.v1"
        static let operatorName = "camera-remote.capture.operatorName.v1"
        static let mainsFrequency = "camera-remote.mainsFrequency.v1"
        static let shootingType = "camera-remote.shootingType.v1"
        static let scaleDistance = "camera-remote.scale.distance.v1"
        static let featureSize = "camera-remote.scale.featureSize.v1"
        static let featureMinimumPixels = "camera-remote.scale.featureMinimumPixels.v2"
        static let playsCaptureSounds = "camera-remote.capture.playsSounds.v1"
        /// Set once `keepEarlierDefaults` has run.
        static let defaultsChecked = "camera-remote.defaults.checked.v1"

        static func lastSession(_ mode: CaptureMode) -> String {
            "camera-remote.capture.lastSession.\(mode.rawValue).v1"
        }
    }

    init() {
        Self.keepEarlierDefaults(defaults)
        captureMode = defaults.string(forKey: Keys.captureMode).flatMap(CaptureMode.init(rawValue:)) ?? .simple
        simpleNaming = defaults.string(forKey: Keys.simpleNaming).flatMap(SimpleNaming.init(rawValue:)) ?? .template
        rootFolder =
            defaults.string(forKey: Keys.rootFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL.picturesDirectory.appending(path: "Simple Camera Remote", directoryHint: .isDirectory)
        sampleTemplate =
            defaults.string(forKey: Keys.sampleTemplate).flatMap { try? FileNameTemplate($0, mode: .sampleWorkflow) }
            ?? .standardSample
        simpleTemplate =
            defaults.string(forKey: Keys.simpleTemplate).flatMap { try? FileNameTemplate($0, mode: .simple) }
            ?? .standardSimple
        grades = defaults.stringArray(forKey: Keys.grades) ?? Self.defaultGrades
        operatorName = defaults.string(forKey: Keys.operatorName) ?? ""
        let mains = defaults.integer(forKey: Keys.mainsFrequency)
        mainsFrequency = [50, 60].contains(mains) ? mains : Self.localMainsFrequency
        shootingType =
            defaults.string(forKey: Keys.shootingType).flatMap(Advisory.ShootingType.init(rawValue:)) ?? .product
        scaleDistance = defaults.object(forKey: Keys.scaleDistance) as? Double
        featureSize = (defaults.object(forKey: Keys.featureSize) as? Double) ?? 2
        // Detectors find objects much under 16–32 px hard; 20 is a modest floor.
        featureMinimumPixels = (defaults.object(forKey: Keys.featureMinimumPixels) as? Double) ?? 20
        playsCaptureSounds = defaults.object(forKey: Keys.playsCaptureSounds) as? Bool ?? true
    }

    /// Before 0.2.0 a new install started in the sample workflow with every
    /// dataset check and 50 Hz.  An install from then (it has settings of
    /// its own) keeps those wherever they were never changed, so updating
    /// doesn't change how it works, and skips the welcome.  A new install
    /// saves today's defaults, so a later change of default won't change it
    /// either.  Checked once, on the first launch of 0.2.0 or later.
    private static func keepEarlierDefaults(_ defaults: UserDefaults) {
        guard defaults.object(forKey: Keys.defaultsChecked) == nil else { return }
        defaults.set(true, forKey: Keys.defaultsChecked)
        let saved = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        let isEarlierInstall = saved.keys.contains {
            $0.hasPrefix("camera-remote.") && $0 != WelcomeView.shownKey && $0 != Keys.defaultsChecked
        }
        let initial: [String: Any] =
            isEarlierInstall
            ? [
                Keys.captureMode: CaptureMode.sampleWorkflow.rawValue,
                Keys.shootingType: Advisory.ShootingType.dataset.rawValue,
                Keys.mainsFrequency: 50,
                WelcomeView.shownKey: true,
            ]
            : [
                Keys.captureMode: CaptureMode.simple.rawValue,
                Keys.shootingType: Advisory.ShootingType.product.rawValue,
                Keys.mainsFrequency: localMainsFrequency,
            ]
        for (key, value) in initial where saved[key] == nil {
            defaults.set(value, forKey: key)
        }
    }

    /// The mains frequency where this Mac is set up, as a first guess: 60 Hz
    /// in the Americas and a few other places, 50 Hz elsewhere (Japan,
    /// split between the two, included).
    private static var localMainsFrequency: Int {
        let sixtyHertz: Set<String> = [
            "US", "CA", "MX", "BR", "CO", "VE", "EC", "PE", "CR", "PA", "GT", "HN", "SV", "NI", "DO", "PR", "CU",
            "HT", "BS", "BZ", "GU", "TW", "KR", "PH", "SA",
        ]
        guard let region = Locale.current.region?.identifier else { return 50 }
        return sixtyHertz.contains(region) ? 60 : 50
    }

    /// The template captures are named with now; nil when they keep the
    /// camera's names.
    var activeTemplate: FileNameTemplate? {
        switch (captureMode, simpleNaming) {
        case (.sampleWorkflow, _): sampleTemplate
        case (.simple, .template): simpleTemplate
        case (.simple, .cameraNames): nil
        }
    }

    /// Uses `pattern` for `mode` if it's a valid template for it.
    func setTemplate(_ pattern: String, for mode: CaptureMode) throws(FileNameTemplate.Error) {
        let template = try FileNameTemplate(pattern, mode: mode)
        switch mode {
        case .sampleWorkflow:
            sampleTemplate = template
            defaults.set(pattern, forKey: Keys.sampleTemplate)
        case .simple:
            simpleTemplate = template
            defaults.set(pattern, forKey: Keys.simpleTemplate)
        }
    }

    /// The session last opened in `mode`, reopened at launch.
    func lastSessionName(for mode: CaptureMode) -> String? {
        defaults.string(forKey: Keys.lastSession(mode))
    }

    func setLastSessionName(_ name: String, for mode: CaptureMode) {
        defaults.set(name, forKey: Keys.lastSession(mode))
    }
}
