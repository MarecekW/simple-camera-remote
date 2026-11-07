import Foundation

/// Everything known about one capture, written next to its files as JSON and
/// as a row of the session's CSV — so the dataset can be traced back to the
/// exact sample, side and camera settings.
public struct CaptureRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    /// The camera settings a record keeps, in CSV column order.
    public enum Setting: String, CaseIterable, Codable, Sendable {
        case focalLength, aperture, shutterSpeed, iso, exposureCompensation, exposureMode
        case whiteBalance, colorTemperature, focusMode, fileFormat, jpegQuality, imageSize, aspectRatio
        case dynamicRangeOptimizer, rawCompression, driveMode
        case lensCompensationShading, lensCompensationChromaticAberration, lensCompensationDistortion

        /// How the setting is named for the user, e.g. in an advisory.
        public var label: String {
            switch self {
            case .focalLength: "Focal length"
            case .aperture: "Aperture"
            case .shutterSpeed: "Shutter speed"
            case .iso: "ISO"
            case .exposureCompensation: "Exposure compensation"
            case .exposureMode: "Exposure mode"
            case .whiteBalance: "White balance"
            case .colorTemperature: "Colour temperature"
            case .focusMode: "Focus mode"
            case .fileFormat: "File format"
            case .jpegQuality: "JPEG quality"
            case .imageSize: "Image size"
            case .aspectRatio: "Aspect ratio"
            case .dynamicRangeOptimizer: "DRO"
            case .rawCompression: "RAW compression"
            case .driveMode: "Drive mode"
            case .lensCompensationShading: "Shading correction"
            case .lensCompensationChromaticAberration: "Chromatic aberration correction"
            case .lensCompensationDistortion: "Distortion correction"
            }
        }
    }

    /// The scale estimate and its inputs (an estimate for planning, not a
    /// measurement).
    public struct Scale: Codable, Equatable, Sendable {
        /// Millimetres from the sensor plane to the subject, as entered.
        public var distance: Double
        public var focalLength: Double
        public var pixelsPerMillimetre: Double
        /// The subject area the frame covers, millimetres.
        public var fieldWidth: Double
        public var fieldHeight: Double

        public init(_ estimate: ResolutionEstimate) {
            distance = estimate.distance
            focalLength = estimate.focalLength
            pixelsPerMillimetre = estimate.pixelsPerMillimetre
            fieldWidth = estimate.fieldOfView.width
            fieldHeight = estimate.fieldOfView.height
        }
    }

    /// A setting as the camera sent it and as the app showed it.
    public struct SettingValue: Codable, Equatable, Sendable {
        public var raw: String
        public var display: String

        public init(raw: String, display: String) {
            self.raw = raw
            self.display = display
        }
    }

    public struct File: Codable, Equatable, Sendable {
        /// The name on the Mac.
        public var name: String
        /// The name on the camera's card, e.g. `DSC01135.ARW`.
        public var cameraName: String
        public var bytes: Int
        public var sha256: String

        public init(name: String, cameraName: String, bytes: Int, sha256: String) {
            self.name = name
            self.cameraName = cameraName
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    public struct Camera: Codable, Equatable, Sendable {
        public var model: String
        public var serialNumber: String?
        public var lens: String?

        public init(model: String, serialNumber: String? = nil, lens: String?) {
            self.model = model
            self.serialNumber = serialNumber
            self.lens = lens
        }
    }

    /// The sample in front of the camera, in the sample workflow.
    public struct Sample: Codable, Equatable, Sendable {
        public var pallet: String
        public var grade: String
        public var load: Int
        public var side: Int
        public var slots: [Int]
        public var stripIDs: [String]

        public init(_ workflow: SampleWorkflow) {
            pallet = workflow.pallet
            grade = workflow.grade
            load = workflow.load
            side = workflow.side
            slots = Array(workflow.slots)
            stripIDs = workflow.stripIDs
        }
    }

    public var schemaVersion = Self.currentSchemaVersion
    public var appVersion: String
    public var capturedAt: Date
    public var session: String
    public var sequence: Int
    public var sample: Sample?
    public var files: [File]
    public var camera: Camera
    /// Keyed by `Setting` raw value; settings the camera didn't report are absent.
    public var settings: [String: SettingValue]
    /// The scale estimate when the capture was taken; nil without a working
    /// distance (and in records from before it was recorded).
    public var scale: Scale?
    /// What could make this capture inconsistent with others; nil in records
    /// from before advisories were recorded.  Only in the sidecar: a CSV
    /// column would shift existing session logs.
    public var advisories: [Advisory]?
    // The four below are nil when unset, and in records from before them.
    /// What the frame shows when it's for calibration, not a sample.
    public var calibration: CalibrationTarget?
    /// The session's measured scale when the capture was taken.
    public var measuredScale: MeasuredScale?
    /// Who took it, as set in Settings.
    public var operatorName: String?
    /// Only in the sidecar: notes may span lines, and the log's rows don't.
    public var sessionNotes: String?

    /// The record of the capture `session` is about to take (its
    /// `nextSequence`, its sample's current side, its notes and measured
    /// scale).
    public init(
        appVersion: String,
        capturedAt: Date,
        session: CaptureSession,
        files: [File],
        camera: Camera,
        settings: [Setting: SettingValue],
        advisories: [Advisory] = [],
        scale: Scale? = nil,
        calibration: CalibrationTarget? = nil,
        operatorName: String? = nil
    ) {
        self.appVersion = appVersion
        self.capturedAt = capturedAt
        self.session = session.name
        sequence = session.nextSequence
        sample = session.sample.map(Sample.init)
        self.files = files
        self.camera = camera
        self.settings = Dictionary(uniqueKeysWithValues: settings.map { ($0.key.rawValue, $0.value) })
        self.advisories = advisories
        self.scale = scale
        self.calibration = calibration
        measuredScale = session.measuredScale
        self.operatorName = operatorName
        sessionNotes = session.notes
    }

    // MARK: - JSON

    /// Pretty, key-sorted JSON, so sidecars diff cleanly.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> CaptureRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CaptureRecord.self, from: data)
    }

    // MARK: - CSV

    static let calibrationColumn = "calibration"

    /// The log's columns.  Readers find columns by position, so new ones
    /// only ever go at the end (`CaptureStore` adds them to older logs).
    public static let csvColumns =
        [
            "session", "sequence", "captured_at", "pallet", "grade", "load", "side", "slots", "strip_ids", "files",
            "sha256", "camera", "lens",
        ] + Setting.allCases.map(\.rawValue) + [calibrationColumn, "operator"]

    public static var csvHeader: String {
        csvColumns.map(csvField).joined(separator: ",")
    }

    /// One CSV line (no newline); settings as displayed; sample columns empty
    /// outside the sample workflow.
    public var csvRow: String {
        let identity = [session, String(sequence), capturedAt.ISO8601Format()]
        let sampleColumns: [String] =
            if let sample {
                [
                    sample.pallet, sample.grade, String(sample.load), String(sample.side),
                    sample.slots.map(String.init).joined(separator: " "), sample.stripIDs.joined(separator: " "),
                ]
            } else {
                Array(repeating: "", count: 6)
            }
        // Names can contain spaces (simple sessions), so lists use ";".
        let fileColumns = [files.map(\.name).joined(separator: ";"), files.map(\.sha256).joined(separator: ";")]
        let cameraColumns = [camera.model, camera.lens ?? ""]
        let settingColumns = Setting.allCases.map { settings[$0.rawValue]?.display ?? "" }
        let laterColumns = [calibration?.rawValue ?? "", operatorName ?? ""]
        let columns = identity + sampleColumns + fileColumns + cameraColumns + settingColumns + laterColumns
        return columns.map(Self.csvField).joined(separator: ",")
    }

    /// RFC 4180: quote fields containing a comma, quote or line break.
    private static func csvField(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
