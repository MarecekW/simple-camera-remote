import Foundation

/// A named setup to come back to: the camera settings the user chose, the AF
/// point, and how the live view is laid out (guides, grid, overlay).  Saved
/// as readable JSON, one file per preset, so presets can be backed up,
/// shared and kept with a dataset.  The file's name is the preset's name, so
/// a file copied or renamed in Finder is a preset of that name.
///
/// Camera settings are kept as the camera's own codes and values — what's
/// sent back on recall — with the displayed value alongside for people
/// reading the file.  The lens position isn't kept: the A6700 can't be sent
/// to an absolute zoom or focus position.
public struct Preset: Codable, Equatable, Sendable {
    public struct CameraSetting: Codable, Equatable, Sendable {
        /// The property code, e.g. 0x500E.
        public var code: UInt16
        public var value: Value
        /// The value as the app shows it, e.g. "M"; for reading only.
        public var display: String

        public init(code: UInt16, value: Value, display: String) {
            self.code = code
            self.value = value
            self.display = display
        }

        private enum CodingKeys: String, CodingKey {
            case code, value, display
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let code = try container.decode(String.self, forKey: .code)
            guard code.hasPrefix("0x"), let number = UInt16(code.dropFirst(2), radix: 16) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .code, in: container, debugDescription: "Expected a hex code like 0x500E, got \(code)")
            }
            self.code = number
            value = try container.decode(Value.self, forKey: .value)
            display = try container.decodeIfPresent(String.self, forKey: .display) ?? ""
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(String(format: "0x%04X", code), forKey: .code)
            try container.encode(value, forKey: .value)
            try container.encode(display, forKey: .display)
        }
    }

    /// A setting's value as the camera sends it: signed (e.g. exposure
    /// compensation) or unsigned.  Written as decimal for signed values and
    /// hex for unsigned ones, as in the capture records.
    public enum Value: Codable, Hashable, Sendable {
        case signed(Int64)
        case unsigned(UInt64)

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if text.hasPrefix("0x"), let number = UInt64(text.dropFirst(2), radix: 16) {
                self = .unsigned(number)
            } else if let number = Int64(text) {
                self = .signed(number)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Expected a hex or decimal value, got \(text)")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .signed(let number): try container.encode(String(number))
            case .unsigned(let number): try container.encode("0x" + String(number, radix: 16, uppercase: true))
            }
        }
    }

    /// A point on the live-view image, 0…1 across and down.
    public struct Point: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// How the live view is laid out.
    public struct View: Codable, Equatable, Sendable {
        public var showsGrid: Bool
        public var showsCrosshair: Bool
        public var showsRulers: Bool
        public var guides: Guides
        /// The overlay image's file, if one was chosen.
        public var overlayPath: String?
        public var showsOverlay: Bool
        public var overlayOpacity: Double

        public init(
            showsGrid: Bool, showsCrosshair: Bool, showsRulers: Bool, guides: Guides, overlayPath: String?,
            showsOverlay: Bool, overlayOpacity: Double
        ) {
            self.showsGrid = showsGrid
            self.showsCrosshair = showsCrosshair
            self.showsRulers = showsRulers
            self.guides = guides
            self.overlayPath = overlayPath
            self.showsOverlay = showsOverlay
            self.overlayOpacity = overlayOpacity
        }
    }

    /// The file's name, without the extension; not stored in the file.
    public var name: String
    /// The camera model it was saved with, e.g. "ILCE-6700"; settings may
    /// not carry over to another model.
    public var camera: String
    public var savedAt: Date
    /// In the order they're applied.
    public var settings: [CameraSetting]
    /// Where the AF frame was, when the focus area has a movable one.
    public var afPoint: Point?
    public var view: View

    /// The format written; files from a newer app are refused rather than
    /// half read.
    public static let currentVersion = 1
    private var version = Self.currentVersion

    public init(
        name: String, camera: String, savedAt: Date, settings: [CameraSetting], afPoint: Point?, view: View
    ) {
        self.name = name
        self.camera = camera
        self.savedAt = savedAt
        self.settings = settings
        self.afPoint = afPoint
        self.view = view
    }

    private enum CodingKeys: String, CodingKey {
        case version, camera, savedAt, settings, afPoint, view
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version <= Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container, debugDescription: "Saved by a newer version of the app")
        }
        name = ""
        camera = try container.decode(String.self, forKey: .camera)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        settings = try container.decode([CameraSetting].self, forKey: .settings)
        afPoint = try container.decodeIfPresent(Point.self, forKey: .afPoint)
        view = try container.decode(View.self, forKey: .view)
    }
}

extension Preset {
    /// The settings to recall, limited to `codes` (the settings the app
    /// keeps) and in their order, which is the order they must be applied;
    /// the first of any repeated code counts.  A hand-edited file may name
    /// other settings: those are returned in `ignored`, never to be sent —
    /// a value the camera doesn't support once crashed the A6700.
    public func settings(limitedTo codes: [UInt16]) -> (recalled: [CameraSetting], ignored: [UInt16]) {
        let recalled = codes.compactMap { code in settings.first { $0.code == code } }
        var ignored: [UInt16] = []
        for setting in settings where !codes.contains(setting.code) && !ignored.contains(setting.code) {
            ignored.append(setting.code)
        }
        return (recalled, ignored)
    }
}

/// The presets in a folder, one JSON file each, named after the preset.
public struct PresetLibrary: Sendable {
    public enum NameProblem: Error, Equatable, Sendable {
        case empty
        /// Characters a file name can't hold.
        case invalidCharacters
        /// Another preset already has the name (ignoring case, as the file
        /// system does).
        case taken
    }

    public let folder: URL

    public static let fileExtension = "json"

    public init(folder: URL) {
        self.folder = folder
    }

    /// Every readable preset, sorted by name as Finder sorts; unreadable
    /// files are skipped and named in `unreadable`.
    public func load() -> (presets: [Preset], unreadable: [String]) {
        let files =
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var presets: [Preset] = []
        var unreadable: [String] = []
        let decoder = Self.decoder
        for file in files where file.pathExtension == Self.fileExtension {
            if let data = try? Data(contentsOf: file), var preset = try? decoder.decode(Preset.self, from: data) {
                preset.name = file.deletingPathExtension().lastPathComponent
                presets.append(preset)
            } else {
                unreadable.append(file.lastPathComponent)
            }
        }
        presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (presets, unreadable.sorted())
    }

    /// Writes `preset` to its file, replacing a preset of the same name.
    public func save(_ preset: Preset) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encoder.encode(preset).write(to: file(for: preset.name), options: .atomic)
    }

    /// Renames the preset called `oldName` — its file.  A change of case
    /// alone goes through a temporary name, so it takes on any volume.
    public func rename(_ oldName: String, to newName: String) throws {
        let manager = FileManager.default
        let temporary = folder.appending(path: UUID().uuidString, directoryHint: .notDirectory)
        try manager.moveItem(at: file(for: oldName), to: temporary)
        do {
            try manager.moveItem(at: temporary, to: file(for: newName))
        } catch {
            try? manager.moveItem(at: temporary, to: file(for: oldName))
            throw error
        }
    }

    /// `name` without the spaces around it, as a preset is named.
    public static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The problem with naming a preset `name` (trimmed), if any; `existing`
    /// are the other presets' names (leave out the one being renamed).
    public static func problem(with name: String, existing: [String]) -> NameProblem? {
        let trimmed = trimmed(name)
        if trimmed.isEmpty { return .empty }
        if trimmed.hasPrefix(".") || trimmed.contains(where: { "/:".contains($0) }) {
            return .invalidCharacters
        }
        if existing.contains(where: { $0.lowercased() == trimmed.lowercased() }) { return .taken }
        return nil
    }

    public func file(for name: String) -> URL {
        folder.appending(path: name + "." + Self.fileExtension, directoryHint: .notDirectory)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
