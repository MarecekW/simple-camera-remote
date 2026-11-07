import CryptoKit
import Foundation
import os

/// Writes captures to disk, off the main actor (hashing and writing tens of
/// megabytes must not stall the live view).
///
/// Each session has its own folder, which holds the files, a JSON sidecar per
/// capture, `session.csv` and `session.json`.  Files are written to
/// `.incoming` first and moved into place only when complete, and existing
/// files are never overwritten.
public actor CaptureStore {
    public enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        /// A file with this name already exists; nothing was overwritten.
        case fileExists(String)
        /// Only the session's latest capture can be deleted; this sequence
        /// number isn't it.
        case notTheLatestCapture(Int)
        /// The capture's sidecar, which lists its files, can't be read, so
        /// they aren't known for certain; nothing was deleted.
        case unknownFiles(Int)

        public var errorDescription: String? {
            switch self {
            case .fileExists(let name): "\(name) already exists"
            case .notTheLatestCapture(let sequence): "capture \(sequence) isn't the session's latest"
            case .unknownFiles: "its sidecar, which lists its files, can't be read"
            }
        }
    }

    /// A capture that couldn't be stored: why, and the files that couldn't
    /// be kept in `unassigned/` either.  Downloading removed those from the
    /// camera's memory, so this is their only copy — the caller must rescue
    /// them.
    public struct StoreFailure: Swift.Error, LocalizedError {
        public let reason: any Swift.Error
        public let unkept: [IncomingFile]

        public var errorDescription: String? { reason.localizedDescription }
    }

    /// A downloaded file, as the camera named it.
    public struct IncomingFile: Sendable {
        public let cameraName: String
        public let data: Data

        public init(cameraName: String, data: Data) {
            self.cameraName = cameraName
            self.data = data
        }
    }

    public nonisolated let root: URL
    private let fileManager = FileManager.default
    /// The app's capture log (CaptureCore can't see the app's `Log`).
    private static let log = Logger(subsystem: "dev.marekkramar.SimpleCameraRemote", category: "capture")

    public init(root: URL) {
        self.root = root
    }

    // MARK: - Sessions

    public nonisolated func directory(for session: CaptureSession, on date: Date) -> URL {
        root.appending(path: session.folderName(on: date), directoryHint: .isDirectory)
    }

    public func loadSession(in directory: URL) throws -> CaptureSession? {
        let url = directory.appending(path: "session.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(CaptureSession.self, from: Data(contentsOf: url))
    }

    public func saveSession(_ state: CaptureSession, in directory: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: directory.appending(path: "session.json"), options: .atomic)
    }

    /// The latest capture recorded in the folder's `session.csv` — the
    /// authority on what was taken, should `session.json` fall behind.
    public func lastRecordedCapture(in directory: URL) throws -> RecordedCapture? {
        let csv = directory.appending(path: "session.csv")
        guard fileManager.fileExists(atPath: csv.path) else { return nil }
        let rows = try String(contentsOf: csv, encoding: .utf8).split(whereSeparator: \.isNewline).dropFirst()
        return rows.compactMap { RecordedCapture(fields: Self.fields(of: $0)) }.max { $0.sequence < $1.sequence }
    }

    /// The settings of the folder's first recorded capture, as displayed —
    /// what later captures should keep to.
    public func firstRecordedSettings(in directory: URL) throws -> [CaptureRecord.Setting: String]? {
        let csv = directory.appending(path: "session.csv")
        guard fileManager.fileExists(atPath: csv.path) else { return nil }
        let rows = try String(contentsOf: csv, encoding: .utf8).split(whereSeparator: \.isNewline)
        guard rows.count > 1 else { return nil }
        let header = Self.fields(of: rows[0])
        let first = Self.fields(of: rows[1])
        var settings: [CaptureRecord.Setting: String] = [:]
        for (column, value) in zip(header, first) where !value.isEmpty {
            if let setting = CaptureRecord.Setting(rawValue: column) { settings[setting] = value }
        }
        return settings
    }

    /// The latest saved sample session of `pallet` from an earlier day, so a
    /// pallet continued on another day keeps counting loads (and strip IDs
    /// stay unique).
    public func latestEarlierSession(ofPallet pallet: String, before directory: URL) throws -> CaptureSession? {
        let suffix = "_" + CaptureSession.folderSafe(pallet)
        guard fileManager.fileExists(atPath: root.path) else { return nil }
        let candidates = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(suffix) && $0.lastPathComponent < directory.lastPathComponent }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for candidate in candidates {
            if let session = try loadSession(in: candidate), session.sample?.pallet == pallet { return session }
        }
        return nil
    }

    /// The highest sequence number among the names `template` could have
    /// given the files in `directory` — sidecars and files a crash left
    /// without a record included, so numbering goes on after them.
    public func highestSequence(in directory: URL, namedBy template: FileNameTemplate) throws -> Int? {
        guard fileManager.fileExists(atPath: directory.path) else { return nil }
        return try fileManager.contentsOfDirectory(atPath: directory.path)
            .compactMap {
                template.sequence(in: CalibrationTarget.removingSuffix(from: ($0 as NSString).deletingPathExtension))
            }
            .max()
    }

    /// Moves files a crash left in `.incoming` to `unassigned/`; returns how
    /// many there were.
    public func recoverIncomingFiles(in directory: URL) throws -> Int {
        let incoming = directory.appending(path: ".incoming", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: incoming.path) else { return 0 }
        let leftovers = try fileManager.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil)
        for file in leftovers {
            try moveToUnassigned(file, in: directory)
        }
        return leftovers.count
    }

    /// The bytes all files in `directory` take, subfolders included.
    public func totalSize(of directory: URL) -> Int64 {
        guard
            let files = fileManager.enumerator(
                at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    // MARK: - Captures

    /// Stores a capture's files as `baseName` + the camera's extension — or
    /// under the camera's own names when `baseName` is nil — with their
    /// checksums.  Never overwrites: if a name is taken, or anything fails,
    /// all the capture's files end up in `unassigned/` instead, and it
    /// throws a `StoreFailure` listing any that couldn't be kept there.
    public func store(_ files: [IncomingFile], baseName: String?, in directory: URL) throws -> [CaptureRecord.File] {
        let destinations = files.map { file in
            directory.appending(
                path: baseName.map { Self.name($0, extensionOf: file.cameraName) } ?? Self.safeName(file.cameraName))
        }
        if let taken = destinations.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            throw StoreFailure(
                reason: Error.fileExists(taken.lastPathComponent), unkept: keepUnassigned(files, in: directory))
        }
        let incoming = directory.appending(path: ".incoming", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: incoming, withIntermediateDirectories: true)
        } catch {
            throw StoreFailure(reason: error, unkept: keepUnassigned(files, in: directory))
        }

        var stored: [CaptureRecord.File] = []
        for (index, (file, destination)) in zip(files, destinations).enumerated() {
            let staging = incoming.appending(path: destination.lastPathComponent)
            do {
                try file.data.write(to: staging, options: .withoutOverwriting)
                // moveItem refuses to replace an existing file, so a name
                // taken in the meantime fails instead of being overwritten.
                try fileManager.moveItem(at: staging, to: destination)
            } catch {
                // A half-stored capture has no record: every one of its files
                // goes to unassigned/, so none keeps a template name or
                // blocks the retake.  A file that can't be moved there is
                // written there afresh from memory; one that can't be
                // written either is handed back.
                var rewrite = Array(files[(index + 1)...])
                for (earlier, record) in zip(files, stored)
                where (try? moveToUnassigned(directory.appending(path: record.name), in: directory)) == nil {
                    rewrite.append(earlier)
                }
                if !fileManager.fileExists(atPath: staging.path)
                    || (try? moveToUnassigned(staging, in: directory)) == nil
                {
                    rewrite.append(file)
                }
                throw StoreFailure(reason: error, unkept: keepUnassigned(rewrite, in: directory))
            }
            stored.append(
                CaptureRecord.File(
                    name: destination.lastPathComponent,
                    cameraName: file.cameraName,
                    bytes: file.data.count,
                    sha256: Self.sha256(file.data)
                ))
        }
        return stored
    }

    /// Writes the capture's sidecar (`<baseName>.json`) and appends its row
    /// to `session.csv`, creating the CSV with a header first.  If that
    /// fails, the capture's files and sidecar move to `unassigned/`, so the
    /// retake can use the same name.
    public func record(_ record: CaptureRecord, baseName: String, in directory: URL) throws {
        let sidecar = directory.appending(path: baseName + ".json")
        // Staged and moved into place like the files, so a crash never
        // leaves a half-written sidecar (and moveItem never overwrites).
        let incoming = directory.appending(path: ".incoming", directoryHint: .isDirectory)
        let staging = incoming.appending(path: sidecar.lastPathComponent)
        do {
            try fileManager.createDirectory(at: incoming, withIntermediateDirectories: true)
            try record.jsonData().write(to: staging, options: .atomic)
            try fileManager.moveItem(at: staging, to: sidecar)
            let csv = directory.appending(path: "session.csv")
            if fileManager.fileExists(atPath: csv.path) {
                try addLaterColumns(to: csv)
            } else {
                try Data((CaptureRecord.csvHeader + "\n").utf8).write(to: csv, options: .withoutOverwriting)
            }
            let handle = try FileHandle(forUpdating: csv)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            do {
                // A crash mid-append can leave a row without its line break;
                // this row starts on a line of its own regardless.
                var row = Data((record.csvRow + "\n").utf8)
                if end > 0 {
                    try handle.seek(toOffset: end - 1)
                    if try handle.read(upToCount: 1) != Data("\n".utf8) { row.insert(UInt8(ascii: "\n"), at: 0) }
                }
                try handle.write(contentsOf: row)
            } catch {
                // No half row for the retake's row to run into.
                try? handle.truncate(atOffset: end)
                throw error
            }
        } catch {
            // The staged copy is only ever the record just made.
            try? fileManager.removeItem(at: staging)
            if fileManager.fileExists(atPath: sidecar.path) { try? moveToUnassigned(sidecar, in: directory) }
            discardStored(record.files, in: directory)
            throw error
        }
    }

    /// Moves a file to the Trash; returns where it went, to put it back.
    public typealias Trash = @Sendable (URL) throws -> URL

    /// Deletes the session's latest capture, `sequence`, and steps `session`
    /// back to retake it (`CaptureSession.rewind`); returns the capture and
    /// the rewound session, saved.  The files its sidecar lists and the
    /// sidecar go to the Trash, and its row leaves `session.csv`.
    ///
    /// All or nothing: if a step fails, whatever went to the Trash is put
    /// back and the log and `session.json` are as they were.  And a crash
    /// part-way never skips the retake: `session.json` is rewound first —
    /// while the row is still logged, reopening catches up past it again —
    /// and the row goes before the files, which a crash would leave without
    /// a record, numbered past like any such files.
    public func deleteLatestCapture(
        _ sequence: Int, rewinding session: CaptureSession, in directory: URL,
        trash: Trash = CaptureStore.moveToTrash
    ) throws -> (deleted: RecordedCapture, session: CaptureSession) {
        let csv = directory.appending(path: "session.csv")
        let original = try String(contentsOf: csv, encoding: .utf8)
        let lines = original.split(whereSeparator: \.isNewline)
        let rows = lines.dropFirst().map { RecordedCapture(fields: Self.fields(of: $0)) }
        guard var latest = rows.compactMap({ $0 }).max(by: { $0.sequence < $1.sequence }),
            latest.sequence == sequence
        else { throw Error.notTheLatestCapture(sequence) }
        // The log's list can be split wrongly (a ";" in a name from before
        // they were refused); the sidecar's can't.
        guard let sidecar = latest.sidecarName, let record = latest.sidecar(in: directory) else {
            throw Error.unknownFiles(sequence)
        }
        latest.files = record.files.map(\.name)
        var rewound = session
        rewound.rewind(toRetake: latest)

        let sessionFile = directory.appending(path: "session.json")
        let savedSession = try? Data(contentsOf: sessionFile)
        let files = (latest.files + [sidecar])
            .map { directory.appending(path: $0) }
            .filter { fileManager.fileExists(atPath: $0.path) }
        var trashed: [(file: URL, inTrash: URL)] = []
        do {
            try saveSession(rewound, in: directory)
            let kept = [lines[0]] + zip(lines.dropFirst(), rows).filter { $0.1?.sequence != sequence }.map(\.0)
            try Data((kept.joined(separator: "\n") + "\n").utf8).write(to: csv, options: .atomic)
            for file in files {
                trashed.append((file, try trash(file)))
            }
        } catch {
            for (file, inTrash) in trashed {
                try? fileManager.moveItem(at: inTrash, to: file)
            }
            try? Data(original.utf8).write(to: csv, options: .atomic)
            if let savedSession {
                try? savedSession.write(to: sessionFile, options: .atomic)
            } else {
                try? fileManager.removeItem(at: sessionFile)
            }
            throw error
        }
        return (latest, rewound)
    }

    /// The Finder's Trash, where a deleted capture can still be got back.
    public static let moveToTrash: Trash = { file in
        var inTrash: NSURL?
        try FileManager.default.trashItem(at: file, resultingItemURL: &inTrash)
        // The system names the new place on success; without it, the file
        // can't be put back, but it is in the Trash.
        return (inTrash as URL?) ?? file
    }

    /// Stores a file that belongs to no capture — an image left in camera
    /// memory by an earlier, interrupted transfer — under its camera name in
    /// `unassigned/`, so it can't be mistaken for the next sample.
    public func storeUnassigned(_ file: IncomingFile, in directory: URL) throws -> URL {
        let destination = try unassignedDestination(for: file.cameraName, in: directory)
        try file.data.write(to: destination, options: .withoutOverwriting)
        return destination
    }

    // MARK: - Private

    /// Brings a log begun by an earlier version up to today's columns: new
    /// columns join the end of its header, and its rows get empty fields
    /// for them — so every row keeps to the header.  A header that isn't an
    /// older form of today's is left alone, and logged: rows appended to it
    /// won't match it.
    private func addLaterColumns(to csv: URL) throws {
        let lines = try String(contentsOf: csv, encoding: .utf8).split(whereSeparator: \.isNewline)
        guard let header = lines.first, header != CaptureRecord.csvHeader else { return }
        guard CaptureRecord.csvHeader.hasPrefix(header + ",") else {
            Self.log.warning(
                "\(csv.path, privacy: .public) has a header this version doesn't know; new rows won't match it")
            return
        }
        let padding = String(repeating: ",", count: CaptureRecord.csvColumns.count - Self.fields(of: header).count)
        let upgraded = [CaptureRecord.csvHeader] + lines.dropFirst().map { $0 + padding }
        try Data((upgraded.joined(separator: "\n") + "\n").utf8).write(to: csv, options: .atomic)
    }

    /// Writes `files` to `unassigned/`; returns those that couldn't be.
    private func keepUnassigned(_ files: [IncomingFile], in directory: URL) -> [IncomingFile] {
        files.filter { (try? storeUnassigned($0, in: directory)) == nil }
    }

    private func moveToUnassigned(_ file: URL, in directory: URL) throws {
        try fileManager.moveItem(at: file, to: unassignedDestination(for: file.lastPathComponent, in: directory))
    }

    /// Moves files of an unrecorded capture out of their template names.  A
    /// file that can't be moved keeps its name — still on disk, not lost —
    /// and the session numbers on past it when it next opens.
    private func discardStored(_ files: [CaptureRecord.File], in directory: URL) {
        for file in files {
            try? moveToUnassigned(directory.appending(path: file.name), in: directory)
        }
    }

    /// A free name for `name` in `unassigned/` ("DSC1.JPG", then "DSC1-2.JPG"…).
    private func unassignedDestination(for name: String, in directory: URL) throws -> URL {
        let folder = directory.appending(path: "unassigned", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = Self.safeName(name)
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var destination = folder.appending(path: safe)
        var attempt = 1
        while fileManager.fileExists(atPath: destination.path) {
            attempt += 1
            destination = folder.appending(path: ext.isEmpty ? "\(base)-\(attempt)" : "\(base)-\(attempt).\(ext)")
        }
        return destination
    }

    /// The fields of a CSV row (RFC 4180 quoting; rows never span lines,
    /// as no recorded value contains a line break).
    private static func fields(of row: Substring) -> [String] {
        var fields: [String] = []
        var field = ""
        var isQuoted = false
        var characters = row.makeIterator()
        while let character = characters.next() {
            switch (character, isQuoted) {
            case ("\"", true):
                // A doubled quote is a literal one; a single one ends quoting.
                if let next = characters.next() {
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        isQuoted = false
                        if next == "," {
                            fields.append(field)
                            field = ""
                        } else {
                            field.append(next)
                        }
                    }
                } else {
                    isQuoted = false
                }
            case ("\"", false) where field.isEmpty: isQuoted = true
            case (",", false):
                fields.append(field)
                field = ""
            default: field.append(character)
            }
        }
        fields.append(field)
        return fields
    }

    private static func name(_ baseName: String, extensionOf cameraName: String) -> String {
        let ext = (cameraName as NSString).pathExtension
        return ext.isEmpty ? baseName : "\(baseName).\(ext.uppercased())"
    }

    /// The camera's file name without any path, never hidden.
    private static func safeName(_ cameraName: String) -> String {
        let name = (cameraName as NSString).lastPathComponent
        let trimmed = String(name.drop { $0 == "." })
        return trimmed.isEmpty ? "unnamed" : trimmed
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
