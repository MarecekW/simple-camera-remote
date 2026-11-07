import Foundation

/// How captures are organised and named.
public enum CaptureMode: String, CaseIterable, Codable, Sendable {
    /// Sample photography: pallet, grade, the load of strips on the rig and
    /// the side facing the camera; each load is shot on four sides.
    case sampleWorkflow
    /// Anything else: a named session and a running number.
    case simple
}

/// A run of captures saved to one folder, e.g. one pallet on one day, or
/// "2026-11-01" in simple mode.  Saved as `session.json`, so the app picks
/// up where it left off.
public struct CaptureSession: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion = Self.currentSchemaVersion
    /// The pallet in the sample workflow; any name in simple mode.
    public var name: String
    /// The next capture's number within the session; starts at 1.
    public var nextSequence: Int
    /// Present in the sample workflow.
    public var sample: SampleWorkflow?
    /// Free text about the session (rig, light, anything unusual), recorded
    /// with each capture; nil when there are none.
    public var notes: String?
    /// The scale measured on one of the session's captures, recorded with
    /// each later one; nil until measured.
    public var measuredScale: MeasuredScale?

    public init(
        name: String, nextSequence: Int = 1, sample: SampleWorkflow? = nil, notes: String? = nil,
        measuredScale: MeasuredScale? = nil
    ) {
        self.name = name
        self.nextSequence = nextSequence
        self.sample = sample
        self.notes = notes
        self.measuredScale = measuredScale
    }

    /// Everything a capture needs is filled in.
    public var isReady: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && (sample?.isReady ?? true)
    }

    /// The session's folder name: `2026-11-01_P012` for a sample session
    /// (one pallet per day), the session name otherwise.  Made safe for a
    /// folder name.
    public func folderName(on date: Date, in timeZone: TimeZone = .current) -> String {
        let name = sample == nil ? self.name : "\(Self.day(of: date, in: timeZone))_\(self.name)"
        return Self.folderSafe(name)
    }

    /// `name` with path separators and colons replaced, for use in a folder name.
    public static func folderSafe(_ name: String) -> String {
        String(name.map { "/\\:".contains($0) ? "-" : $0 })
    }

    /// Characters a session or pallet name can't hold: the log lists a
    /// capture's files joined with ";", and its rows never span lines.
    public static func hasForbiddenCharacters(_ name: String) -> Bool {
        name.contains { $0 == ";" || $0.isNewline }
    }

    /// `text` on one line — inner line breaks become spaces — without the
    /// whitespace around it, for a value the log records.
    public static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// `2026-11-01`: the local calendar day, the default simple-session name.
    public static func day(of date: Date, in timeZone: TimeZone = .current) -> String {
        date.formatted(
            .verbatim(
                "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)", timeZone: timeZone,
                calendar: Calendar(identifier: .gregorian)))
    }

    /// Moves on after a completed capture.  Returns true when the sample
    /// workflow starts a new load — time to reload the rig.  A calibration
    /// frame shows no strips, so it only takes a number: the side it was
    /// shot at is still to do.
    @discardableResult
    public mutating func advanceAfterCompletedCapture(isCalibrationFrame: Bool = false) -> Bool {
        nextSequence += 1
        guard !isCalibrationFrame else { return false }
        return sample?.advance() ?? false
    }

    /// Moves on past `recorded` if this state is behind it — when saving
    /// `session.json` failed after the capture was recorded.
    public mutating func catchUp(with recorded: RecordedCapture) {
        guard recorded.sequence >= nextSequence else { return }
        nextSequence = recorded.sequence
        if var sample, let load = recorded.load, let side = recorded.side {
            sample.load = load
            sample.side = side
            self.sample = sample
        }
        advanceAfterCompletedCapture(isCalibrationFrame: recorded.calibration != nil)
    }

    /// Goes back to where `deleted` was taken — after the latest capture was
    /// deleted — so its retake gets the same number and name, and in the
    /// sample workflow the same load, side and strips.  A scale measured on
    /// it goes with it.
    public mutating func rewind(toRetake deleted: RecordedCapture) {
        nextSequence = deleted.sequence
        if let measuredScale, measuredScale.capture == deleted.name { self.measuredScale = nil }
        if var sample, let load = deleted.load, let side = deleted.side {
            sample.load = load
            sample.side = side
            if let strips = deleted.strips { sample.strips = strips }
            self.sample = sample
        }
    }
}

/// Where the latest capture in `session.csv` stood.
public struct RecordedCapture: Equatable, Sendable {
    public var sequence: Int
    /// Nil outside the sample workflow.
    public var load: Int?
    public var side: Int?
    public var strips: Int?
    public var capturedAt: Date?
    /// The stored file names.
    public var files: [String]
    /// Nil for a sample (and in logs from before calibration frames).
    public var calibration: CalibrationTarget?

    public init(
        sequence: Int, load: Int? = nil, side: Int? = nil, strips: Int? = nil, capturedAt: Date? = nil,
        files: [String] = [], calibration: CalibrationTarget? = nil
    ) {
        self.sequence = sequence
        self.load = load
        self.side = side
        self.strips = strips
        self.capturedAt = capturedAt
        self.files = files
        self.calibration = calibration
    }

    /// The capture's name: its first file's without extension, as its
    /// sidecar is named (`CaptureStore.record`).
    public var name: String? {
        files.first.map { ($0 as NSString).deletingPathExtension }
    }

    public var sidecarName: String? { name.map { $0 + ".json" } }

    /// The capture's sidecar, read from `directory`; nil if it can't be read
    /// or is another capture's.
    public func sidecar(in directory: URL) -> CaptureRecord? {
        guard let sidecarName, let data = try? Data(contentsOf: directory.appending(path: sidecarName)),
            let record = try? CaptureRecord.decode(data), record.sequence == sequence
        else { return nil }
        return record
    }

    /// From a CSV row's fields (`CaptureRecord.csvColumns`): sequence is the
    /// 2nd column, the time the 3rd, load and side the 6th and 7th, the
    /// slots the 8th, the files (joined with ";") the 10th; columns added
    /// later sit at the end, and older logs don't have them.
    init?(fields: [String]) {
        guard fields.count > 9, let sequence = Int(fields[1]) else { return nil }
        let calibrationColumn = CaptureRecord.csvColumns.firstIndex(of: CaptureRecord.calibrationColumn)
        self.init(
            sequence: sequence, load: Int(fields[5]), side: Int(fields[6]),
            strips: fields[7].split(separator: " ").compactMap { Int($0) }.max(),
            capturedAt: try? Date(fields[2], strategy: .iso8601),
            files: fields[9].split(separator: ";").map(String.init),
            calibration: calibrationColumn.flatMap { fields.indices.contains($0) ? fields[$0] : nil }
                .flatMap(CalibrationTarget.init(rawValue:)))
    }
}

/// Where a sample session stands: the pallet's grade, which load of strips is
/// on the rig, and which side faces the camera.  A load of 1–5 strips is shot
/// on each of its four sides; after the fourth side the next load begins.
public struct SampleWorkflow: Codable, Equatable, Sendable {
    public static let sidesPerLoad = 4
    /// A new pallet starts with the rig's usual load.
    public static let defaultStrips = 5
    /// A sanity bound, not the rig's size: loads can be bigger than usual.
    public static let maximumStrips = 99

    public var pallet: String
    public var grade: String
    /// Starts at 1.
    public var load: Int
    /// Strips on the rig, 1…`maximumStrips`; the rig fills from the bottom,
    /// so they occupy slots 1…`strips`.
    public var strips: Int
    /// 1…`sidesPerLoad`.
    public var side: Int

    public init(pallet: String, grade: String = "", load: Int = 1, strips: Int = defaultStrips, side: Int = 1) {
        self.pallet = pallet
        self.grade = grade
        self.load = load
        self.strips = strips
        self.side = side
    }

    public var isReady: Bool { !grade.isEmpty }

    /// The rig slots holding a strip, numbered from the bottom.
    public var slots: ClosedRange<Int> { 1...max(1, strips) }

    /// The load on the rig is past side 1: its earlier sides were recorded
    /// with these strips and this grade, so changing them now would label
    /// the rest of the load differently.
    public var isLoadPartShot: Bool { side > 1 }

    private enum CodingKeys: String, CodingKey {
        case pallet, grade, load, strips, side
        /// Sessions saved before strips became a count listed the slots.
        case filledSlots
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pallet = try container.decode(String.self, forKey: .pallet)
        grade = try container.decode(String.self, forKey: .grade)
        load = try container.decode(Int.self, forKey: .load)
        // Sessions that listed slots become the count up to the highest one
        // (the rig fills from the bottom; gaps weren't meaningful); none
        // listed falls back to the default.
        let decoded =
            try container.decodeIfPresent(Int.self, forKey: .strips)
            ?? container.decode([Int].self, forKey: .filledSlots).max() ?? Self.defaultStrips
        strips = min(max(decoded, 1), Self.maximumStrips)
        side = try container.decode(Int.self, forKey: .side)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pallet, forKey: .pallet)
        try container.encode(grade, forKey: .grade)
        try container.encode(load, forKey: .load)
        try container.encode(strips, forKey: .strips)
        try container.encode(side, forKey: .side)
    }

    /// Stable IDs of the strips on the rig, e.g. `P012-L03-2`: the same for
    /// all four sides of a strip, so a dataset can be split by strip.
    public var stripIDs: [String] {
        slots.map { "\(pallet)-L\(String(format: "%02d", load))-\($0)" }
    }

    /// Next side, or after the last side the first side of the next load.
    /// Returns true when a new load starts.
    mutating func advance() -> Bool {
        guard side >= Self.sidesPerLoad else {
            side += 1
            return false
        }
        side = 1
        load += 1
        return true
    }
}
