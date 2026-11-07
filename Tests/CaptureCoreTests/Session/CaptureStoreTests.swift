import Foundation
import Testing

@testable import CaptureCore

struct CaptureStoreTests {
    private let session = CaptureSession(
        name: "P012", nextSequence: 47,
        sample: SampleWorkflow(pallet: "P012", grade: "B", load: 3, strips: 2, side: 2))

    @Test func storesFilesWithTheirChecksums() async throws {
        try await withTemporaryDirectory { directory in
            let store = CaptureStore(root: directory)
            let files = [
                CaptureStore.IncomingFile(cameraName: "DSC01135.ARW", data: Data("raw".utf8)),
                CaptureStore.IncomingFile(cameraName: "DSC01135.JPG", data: Data("jpeg".utf8)),
            ]
            let stored = try await store.store(files, baseName: "P012_B_L03_S2_0047", in: directory)

            #expect(stored.map(\.name) == ["P012_B_L03_S2_0047.ARW", "P012_B_L03_S2_0047.JPG"])
            #expect(stored.map(\.cameraName) == ["DSC01135.ARW", "DSC01135.JPG"])
            // SHA-256 of "raw".
            #expect(stored[0].sha256 == "d7439bee24773bcbfa2d0a97947ee36227b10d1022b1a55847e928965bb6bfde")
            #expect(try Data(contentsOf: directory.appending(path: "P012_B_L03_S2_0047.JPG")) == Data("jpeg".utf8))
            let incoming = try FileManager.default.contentsOfDirectory(
                atPath: directory.appending(path: ".incoming").path)
            #expect(incoming.isEmpty)
        }
    }

    @Test func neverOverwritesAnExistingFile() async throws {
        try await withTemporaryDirectory { directory in
            let store = CaptureStore(root: directory)
            let existing = directory.appending(path: "NAME.JPG")
            try Data("keep".utf8).write(to: existing)

            let failure = await #expect(throws: CaptureStore.StoreFailure.self) {
                try await store.store(
                    [.init(cameraName: "DSC1.JPG", data: Data("new".utf8))], baseName: "NAME", in: directory)
            }
            #expect(failure?.reason as? CaptureStore.Error == .fileExists("NAME.JPG"))
            #expect(failure?.unkept.isEmpty == true)
            #expect(try Data(contentsOf: existing) == Data("keep".utf8))
            // The new capture is kept, not dropped.
            let kept = directory.appending(path: "unassigned/DSC1.JPG")
            #expect(try Data(contentsOf: kept) == Data("new".utf8))
        }
    }

    @Test func writesTheSidecarAndAppendsCSVRows() async throws {
        try await withTemporaryDirectory { directory in
            let store = CaptureStore(root: directory)
            let record = makeRecord(session)
            try await store.record(record, baseName: "first", in: directory)
            var next = session
            next.advanceAfterCompletedCapture()
            try await store.record(makeRecord(next), baseName: "second", in: directory)

            let sidecar = try CaptureRecord.decode(Data(contentsOf: directory.appending(path: "first.json")))
            #expect(sidecar == record)
            let csv = try String(contentsOf: directory.appending(path: "session.csv"), encoding: .utf8)
            let lines = csv.split(separator: "\n")
            #expect(lines.count == 3)
            #expect(lines[0] == Substring(CaptureRecord.csvHeader))
            #expect(lines[1].hasPrefix("P012,47,"))
            #expect(lines[2].hasPrefix("P012,48,"))
        }
    }

    @Test func keepsLeftoverImagesApartUnderTheCameraName() async throws {
        try await withTemporaryDirectory { directory in
            let store = CaptureStore(root: directory)
            let first = try await store.storeUnassigned(
                .init(cameraName: "DSC00001.JPG", data: Data([1])), in: directory)
            let second = try await store.storeUnassigned(
                .init(cameraName: "../DSC00001.JPG", data: Data([2])), in: directory)
            #expect(first.lastPathComponent == "DSC00001.JPG")
            #expect(second.lastPathComponent == "DSC00001-2.JPG")
            #expect(second.deletingLastPathComponent().lastPathComponent == "unassigned")
        }
    }

    @Test func keepsTheCameraNamesWhenNamingIsOff() async throws {
        try await withTemporaryDirectory { directory in
            let store = CaptureStore(root: directory)
            let stored = try await store.store(
                [.init(cameraName: "DSC01135.ARW", data: Data([1]))], baseName: nil, in: directory)
            #expect(stored.map(\.name) == ["DSC01135.ARW"])
        }
    }

    @Test func remembersTheSession() async throws {
        try await withTemporaryDirectory { directory in
            let store = CaptureStore(root: directory)
            let folder = store.directory(for: session, on: .now)
            #expect(folder.lastPathComponent.hasSuffix("_P012"))
            #expect(try await store.loadSession(in: folder) == nil)
            try await store.saveSession(session, in: folder)
            #expect(try await store.loadSession(in: folder) == session)
        }
    }

    @Test func readsTheFirstCapturesSettings() async throws {
        try await withTemporaryDirectory { directory in
            let store = CaptureStore(root: directory)
            try await store.record(makeRecord(session), baseName: "first", in: directory)
            var next = session
            next.advanceAfterCompletedCapture()
            var later = makeRecord(next)
            later.settings["aperture"] = .init(raw: "0x230", display: "f/5.6")
            try await store.record(later, baseName: "second", in: directory)
            let first = try await store.firstRecordedSettings(in: directory)
            #expect(first == [.aperture: "f/8.0", .shutterSpeed: "1/60"])
        }
    }

    @Test func readsTheLastCapturesFiles() async throws {
        try await withTemporaryDirectory { directory in
            let store = CaptureStore(root: directory)
            var record = makeRecord(session)
            record.files.append(.init(name: "a.JPG", cameraName: "DSC1.JPG", bytes: 2, sha256: "def"))
            try await store.record(record, baseName: "first", in: directory)
            #expect(try await store.lastRecordedCapture(in: directory)?.files == ["a.ARW", "a.JPG"])
        }
    }

    @Test func readsSidecarsFromBeforeAdvisories() throws {
        var json = String(decoding: try makeRecord(session).jsonData(), as: UTF8.self)
        let start = try #require(json.range(of: "  \"advisories\""))
        let end = try #require(json[start.upperBound...].range(of: "],\n"))
        json.removeSubrange(start.lowerBound..<end.upperBound)
        #expect(try CaptureRecord.decode(Data(json.utf8)).advisories == nil)
    }

    @Test func readsTheFirstCaptureByTheFilesOwnHeader() async throws {
        try await withTemporaryDirectory { directory in
            let csv = "session,sequence,aperture,shutterSpeed\n\"Studio, A\",1,\"f/8,0\",1/60\n"
            try Data(csv.utf8).write(to: directory.appending(path: "session.csv"))
            let first = try await CaptureStore(root: directory).firstRecordedSettings(in: directory)
            #expect(first == [.aperture: "f/8,0", .shutterSpeed: "1/60"])
        }
    }

    @Test func aLogWithOnlyAHeaderHasNoFirstCapture() async throws {
        try await withTemporaryDirectory { directory in
            try Data((CaptureRecord.csvHeader + "\n").utf8).write(to: directory.appending(path: "session.csv"))
            let store = CaptureStore(root: directory)
            #expect(try await store.firstRecordedSettings(in: directory) == nil)
            #expect(try await store.lastRecordedCapture(in: directory) == nil)
        }
    }

    @Test func skipsShortRowsAndKeepsABadDateOut() async throws {
        try await withTemporaryDirectory { directory in
            let csv = CaptureRecord.csvHeader + "\nP1,3\nP1,4,yesterday,P1,A,1,2,1 2,x,a.ARW;a.JPG,h,c,l\n"
            try Data(csv.utf8).write(to: directory.appending(path: "session.csv"))
            let last = try #require(try await CaptureStore(root: directory).lastRecordedCapture(in: directory))
            #expect(last.sequence == 4)
            #expect(last.capturedAt == nil)
            #expect(last.files == ["a.ARW", "a.JPG"])
        }
    }

    @Test func addsUpTheFolder() async throws {
        try await withTemporaryDirectory { directory in
            try Data(count: 300).write(to: directory.appending(path: "a.ARW"))
            try FileManager.default.createDirectory(
                at: directory.appending(path: "unassigned"), withIntermediateDirectories: true)
            try Data(count: 200).write(to: directory.appending(path: "unassigned/b.JPG"))
            #expect(await CaptureStore(root: directory).totalSize(of: directory) == 500)
        }
    }

    @Test func roundTripsTheScaleEstimate() throws {
        let estimate = try #require(ResolutionEstimate(focalLength: 35, distance: 450))
        var record = makeRecord(session)
        record.scale = CaptureRecord.Scale(estimate)
        let decoded = try CaptureRecord.decode(try record.jsonData())
        #expect(decoded.scale == record.scale)
        #expect(abs((decoded.scale?.pixelsPerMillimetre ?? 0) - estimate.pixelsPerMillimetre) < 1e-9)
    }

    @Test func startsANewRowAfterAHalfWrittenOne() async throws {
        try await withTemporaryDirectory { directory in
            let store = CaptureStore(root: directory)
            let csv = directory.appending(path: "session.csv")
            try Data((CaptureRecord.csvHeader + "\nP012,46,2026-11-0").utf8).write(to: csv)

            try await store.record(makeRecord(session), baseName: "first", in: directory)

            let lines = try String(contentsOf: csv, encoding: .utf8).split(separator: "\n")
            #expect(lines.count == 3)
            #expect(lines[2].hasPrefix("P012,47,"))
            #expect(try await store.lastRecordedCapture(in: directory)?.sequence == 47)
        }
    }

    // MARK: - Helpers

    private func makeRecord(_ session: CaptureSession) -> CaptureRecord {
        CaptureRecord(
            appVersion: "test",
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            session: session,
            files: [.init(name: "a.ARW", cameraName: "DSC1.ARW", bytes: 3, sha256: "abc")],
            camera: .init(model: "ILCE-6700", lens: "E PZ 18-105mm F4 G OSS"),
            settings: [
                .aperture: .init(raw: "0x320", display: "f/8.0"), .shutterSpeed: .init(raw: "0x1003C", display: "1/60"),
            ],
            advisories: [.init(kind: .autoISO, message: "Auto ISO lets brightness and noise vary — set a fixed ISO.")]
        )
    }
}

struct CaptureRecordTests {
    @Test func quotesCSVFieldsThatNeedIt() {
        let session = CaptureSession(
            name: "P,12", sample: SampleWorkflow(pallet: "P,12", grade: "Rustic \"A\"", strips: 1))
        let record = CaptureRecord(
            appVersion: "test", capturedAt: .now, session: session, files: [],
            camera: .init(model: "ILCE-6700", lens: nil), settings: [:])
        #expect(record.csvRow.contains("\"P,12\""))
        #expect(record.csvRow.contains("\"Rustic \"\"A\"\"\""))
    }

    @Test func headerAndRowHaveTheSameColumns() {
        for session in [
            CaptureSession(name: "Portraits"), CaptureSession(name: "P1", sample: SampleWorkflow(pallet: "P1")),
        ] {
            let record = CaptureRecord(
                appVersion: "test", capturedAt: .now, session: session, files: [],
                camera: .init(model: "ILCE-6700", lens: nil), settings: [:])
            #expect(
                record.csvRow.split(separator: ",", omittingEmptySubsequences: false).count
                    == CaptureRecord.csvHeader.split(separator: ",").count)
        }
    }

    @Test func recordsCalibrationAndOperatorAtTheEndOfTheRow() throws {
        let record = CaptureRecord(
            appVersion: "test", capturedAt: .now, session: CaptureSession(name: "Portraits"), files: [],
            camera: .init(model: "ILCE-6700", lens: nil), settings: [:], calibration: .ruler,
            operatorName: "Kramár, M.")
        #expect(record.csvRow.hasSuffix(",Ruler,\"Kramár, M.\""))
        #expect(CaptureRecord.csvHeader.hasSuffix(",calibration,operator"))
    }

    @Test func recordsTheSessionsNotesAndMeasuredScale() throws {
        let scale = try #require(MeasuredScale(pixels: 431, millimetres: 100, capture: "P1_0001_Ruler"))
        let session = CaptureSession(name: "P1", nextSequence: 2, notes: "Line one\nLine two", measuredScale: scale)
        let record = CaptureRecord(
            appVersion: "test", capturedAt: Date(timeIntervalSince1970: 1_800_000_000), session: session, files: [],
            camera: .init(model: "ILCE-6700", lens: nil), settings: [:], operatorName: "MK")
        #expect(record.sessionNotes == "Line one\nLine two")
        #expect(record.measuredScale == scale)
        #expect(try CaptureRecord.decode(record.jsonData()) == record)
        // Notes stay out of the log, whose rows never span lines.
        #expect(!record.csvRow.contains("Line"))
    }

    @Test func leavesUnsetNewFieldsOutOfTheSidecar() throws {
        // So sidecars look as before, and earlier ones decode with them nil.
        let record = CaptureRecord(
            appVersion: "test", capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            session: CaptureSession(name: "Portraits"), files: [],
            camera: .init(model: "ILCE-6700", lens: nil), settings: [:])
        let json = try #require(String(data: try record.jsonData(), encoding: .utf8))
        for key in ["calibration", "measuredScale", "operatorName", "sessionNotes"] {
            #expect(!json.contains("\"\(key)\""))
        }
        #expect(try CaptureRecord.decode(Data(json.utf8)) == record)
    }

    @Test func aSimpleCaptureHasNoSampleBlock() throws {
        let record = CaptureRecord(
            appVersion: "test", capturedAt: .now, session: CaptureSession(name: "Portraits"), files: [],
            camera: .init(model: "ILCE-6700", lens: nil), settings: [:])
        #expect(record.sample == nil)
        let json = try #require(String(data: try record.jsonData(), encoding: .utf8))
        #expect(!json.contains("\"sample\""))
    }
}

struct CaptureStoreRecoveryTests {
    @Test func readsTheLatestRecordedCaptureEvenWithQuotedNames() async throws {
        try await withTemporaryDirectory { directory in
            let store = CaptureStore(root: directory)
            for (sequence, side) in [(3, 1), (7, 3), (5, 2)] {
                let session = CaptureSession(
                    name: "Pallet \"7\", A", nextSequence: sequence,
                    sample: SampleWorkflow(pallet: "Pallet \"7\", A", grade: "B", load: 2, side: side))
                let record = CaptureRecord(
                    appVersion: "test", capturedAt: .now, session: session, files: [],
                    camera: .init(model: "ILCE-6700", lens: nil), settings: [:])
                try await store.record(record, baseName: "capture\(sequence)", in: directory)
            }
            let last = try #require(try await store.lastRecordedCapture(in: directory))
            #expect(last.sequence == 7)
            #expect(last.load == 2)
            #expect(last.side == 3)
            #expect(last.capturedAt != nil)
        }
    }

    @Test func findsThePalletsSessionFromAnEarlierDay() async throws {
        try await withTemporaryDirectory { root in
            let store = CaptureStore(root: root)
            let earlier = CaptureSession(
                name: "P012", nextSequence: 9, sample: SampleWorkflow(pallet: "P012", grade: "B", load: 3, side: 2))
            try await store.saveSession(earlier, in: root.appending(path: "2026-10-30_P012"))
            try await store.saveSession(CaptureSession(name: "P013"), in: root.appending(path: "2026-10-31_P013"))

            let found = try await store.latestEarlierSession(
                ofPallet: "P012", before: root.appending(path: "2026-11-01_P012"))
            #expect(found == earlier)
            #expect(
                try await store.latestEarlierSession(ofPallet: "P014", before: root.appending(path: "2026-11-01_P014"))
                    == nil)
        }
    }

    @Test func movesCrashLeftoversOutOfTheWay() async throws {
        try await withTemporaryDirectory { directory in
            let store = CaptureStore(root: directory)
            let incoming = directory.appending(path: ".incoming")
            try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
            try Data([1]).write(to: incoming.appending(path: "P1_0001.ARW"))

            #expect(try await store.recoverIncomingFiles(in: directory) == 1)
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: "unassigned/P1_0001.ARW").path))
        }
    }

    @Test func handsBackFilesThatCouldNotBeKeptAnywhere() async throws {
        try await withTemporaryDirectory { directory in
            let store = CaptureStore(root: directory)
            try Data("taken".utf8).write(to: directory.appending(path: "NAME.JPG"))
            // A file where the unassigned/ folder should be.
            try Data().write(to: directory.appending(path: "unassigned"))

            let failure = await #expect(throws: CaptureStore.StoreFailure.self) {
                try await store.store(
                    [.init(cameraName: "DSC1.JPG", data: Data("new".utf8))], baseName: "NAME", in: directory)
            }
            #expect(failure?.unkept.map(\.cameraName) == ["DSC1.JPG"])
            #expect(failure?.unkept.first?.data == Data("new".utf8))
        }
    }

    @Test func numbersOnPastFilesWithoutARecord() async throws {
        try await withTemporaryDirectory { directory in
            let store = CaptureStore(root: directory)
            #expect(try await store.highestSequence(in: directory, namedBy: .standardSample) == nil)
            // A crash after storing, before recording, left these behind.
            for name in ["P012_B_L03_S2_0047.ARW", "P012_B_L03_S2_0047.JPG", "P012_B_L03_S1_0046.json", "notes.txt"] {
                try Data().write(to: directory.appending(path: name))
            }
            #expect(try await store.highestSequence(in: directory, namedBy: .standardSample) == 47)
        }
    }

    @Test func numbersOnPastCalibrationFramesWithoutARecord() async throws {
        try await withTemporaryDirectory { directory in
            try Data().write(to: directory.appending(path: "P012_B_L03_S2_0049_ColorChecker.JPG"))
            let store = CaptureStore(root: directory)
            #expect(try await store.highestSequence(in: directory, namedBy: .standardSample) == 49)
        }
    }

    @Test func addsLaterColumnsToALogBegunByAnEarlierVersion() async throws {
        try await withTemporaryDirectory { directory in
            let csv = directory.appending(path: "session.csv")
            let oldColumns = CaptureRecord.csvColumns.dropLast(2)
            let oldRow =
                ["P1", "1", "2026-11-01T10:00:00Z", "P1", "A", "1", "1", "1 2", "x", "a.ARW;a.JPG"]
                + Array(repeating: "", count: oldColumns.count - 10)
            try Data((oldColumns.joined(separator: ",") + "\n" + oldRow.joined(separator: ",") + "\n").utf8)
                .write(to: csv)
            let store = CaptureStore(root: directory)
            let session = CaptureSession(
                name: "P1", nextSequence: 2, sample: SampleWorkflow(pallet: "P1", grade: "A", load: 1, side: 2))
            let record = CaptureRecord(
                appVersion: "test", capturedAt: .now, session: session, files: [],
                camera: .init(model: "ILCE-6700", lens: nil), settings: [:], calibration: .whiteCard)
            try await store.record(record, baseName: "second", in: directory)

            let lines = try String(contentsOf: csv, encoding: .utf8).split(separator: "\n")
            #expect(lines.count == 3)
            #expect(lines[0] == Substring(CaptureRecord.csvHeader))
            #expect(lines[1] == Substring(oldRow.joined(separator: ",") + ",,"))
            #expect(try await store.lastRecordedCapture(in: directory)?.calibration == .whiteCard)
            #expect(try await store.firstRecordedSettings(in: directory) == [:])
        }
    }

    @Test func aFailedRecordFreesTheNameForTheRetake() async throws {
        try await withTemporaryDirectory { directory in
            let store = CaptureStore(root: directory)
            let stored = try await store.store(
                [.init(cameraName: "DSC1.ARW", data: Data([1]))], baseName: "P1_0001", in: directory)
            // A stray sidecar makes writing the record fail.
            try Data().write(to: directory.appending(path: "P1_0001.json"))
            let record = CaptureRecord(
                appVersion: "test", capturedAt: .now, session: CaptureSession(name: "P1"), files: stored,
                camera: .init(model: "ILCE-6700", lens: nil), settings: [:])

            await #expect(throws: (any Error).self) {
                try await store.record(record, baseName: "P1_0001", in: directory)
            }
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "P1_0001.ARW").path))
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: "unassigned/P1_0001.ARW").path))
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: ".incoming").path)
                    .isEmpty)
            // The retake can use the name again.
            _ = try await store.store(
                [.init(cameraName: "DSC2.ARW", data: Data([2]))], baseName: "P1_0001", in: directory)
        }
    }
}

struct CaptureStoreDeletionTests {
    /// Two recorded captures, 47 and 48, each with a RAW, a JPEG and a
    /// sidecar on disk, and the session saved after them.
    private func recordTwoCaptures(in directory: URL) async throws -> (CaptureStore, CaptureSession) {
        let store = CaptureStore(root: directory)
        var session = CaptureSession(
            name: "P012", nextSequence: 47,
            sample: SampleWorkflow(pallet: "P012", grade: "B", load: 3, strips: 3, side: 4))
        for _ in 0..<2 {
            let name = FileNameTemplate.standardSample.fileName(for: .init(session: session, date: .now))
            let stored = try await store.store(
                [.init(cameraName: "DSC1.ARW", data: Data([1])), .init(cameraName: "DSC1.JPG", data: Data([2]))],
                baseName: name, in: directory)
            let record = CaptureRecord(
                appVersion: "test", capturedAt: .now, session: session, files: stored,
                camera: .init(model: "ILCE-6700", lens: nil), settings: [:])
            try await store.record(record, baseName: name, in: directory)
            session.advanceAfterCompletedCapture()
        }
        try await store.saveSession(session, in: directory)
        return (store, session)
    }

    /// A stand-in for the Finder's Trash: a folder in the test's directory.
    private func trash(in directory: URL) -> CaptureStore.Trash {
        { file in
            let folder = directory.appending(path: "Trash")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appending(path: file.lastPathComponent)
            try FileManager.default.moveItem(at: file, to: destination)
            return destination
        }
    }

    @Test func trashesTheLatestCaptureAndItsRow() async throws {
        try await withTemporaryDirectory { directory in
            let (store, session) = try await recordTwoCaptures(in: directory)
            let (deleted, _) = try await store.deleteLatestCapture(
                48, rewinding: session, in: directory, trash: trash(in: directory))

            #expect(deleted.sequence == 48)
            #expect(deleted.load == 4)
            #expect(deleted.side == 1)
            #expect(deleted.strips == 3)
            let trashed = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "Trash").path)
            #expect(
                Set(trashed) == ["P012_B_L04_S1_0048.ARW", "P012_B_L04_S1_0048.JPG", "P012_B_L04_S1_0048.json"])
            #expect(try await store.lastRecordedCapture(in: directory)?.sequence == 47)
            let csv = try String(contentsOf: directory.appending(path: "session.csv"), encoding: .utf8)
            #expect(csv.split(separator: "\n").count == 2)
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: "P012_B_L03_S4_0047.ARW").path))
        }
    }

    @Test func savesTheSessionRewoundForTheRetake() async throws {
        try await withTemporaryDirectory { directory in
            let (store, session) = try await recordTwoCaptures(in: directory)
            #expect(session.sample?.side == 2)
            let (_, rewound) = try await store.deleteLatestCapture(
                48, rewinding: session, in: directory, trash: trash(in: directory))

            #expect(rewound.nextSequence == 48)
            #expect(rewound.sample == SampleWorkflow(pallet: "P012", grade: "B", load: 4, strips: 3, side: 1))
            // Saved with the rest, so reopening can't resume past the side.
            #expect(try await store.loadSession(in: directory) == rewound)
        }
    }

    @Test func onlyTheLatestCaptureCanBeDeleted() async throws {
        try await withTemporaryDirectory { directory in
            let (store, session) = try await recordTwoCaptures(in: directory)
            let csv = directory.appending(path: "session.csv")
            let before = try Data(contentsOf: csv)
            await #expect(throws: CaptureStore.Error.notTheLatestCapture(47)) {
                try await store.deleteLatestCapture(47, rewinding: session, in: directory, trash: trash(in: directory))
            }
            #expect(try Data(contentsOf: csv) == before)
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: "P012_B_L03_S4_0047.ARW").path))
        }
    }

    @Test func putsEverythingBackWhenAFileCantBeTrashed() async throws {
        try await withTemporaryDirectory { directory in
            let (store, session) = try await recordTwoCaptures(in: directory)
            let csv = directory.appending(path: "session.csv")
            let before = try Data(contentsOf: csv)
            let toTrash = trash(in: directory)
            let failsOnTheJPEG: CaptureStore.Trash = { file in
                guard file.pathExtension != "JPG" else { throw CocoaError(.fileWriteNoPermission) }
                return try toTrash(file)
            }
            await #expect(throws: CocoaError.self) {
                try await store.deleteLatestCapture(48, rewinding: session, in: directory, trash: failsOnTheJPEG)
            }
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: "P012_B_L04_S1_0048.ARW").path))
            #expect(try Data(contentsOf: csv) == before)
            #expect(try await store.loadSession(in: directory) == session)
        }
    }

    @Test func refusesWithoutTheSidecarThatListsTheFiles() async throws {
        try await withTemporaryDirectory { directory in
            let (store, session) = try await recordTwoCaptures(in: directory)
            try FileManager.default.removeItem(at: directory.appending(path: "P012_B_L04_S1_0048.json"))
            let csv = directory.appending(path: "session.csv")
            let before = try Data(contentsOf: csv)
            await #expect(throws: CaptureStore.Error.unknownFiles(48)) {
                try await store.deleteLatestCapture(48, rewinding: session, in: directory, trash: trash(in: directory))
            }
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: "P012_B_L04_S1_0048.ARW").path))
            #expect(try Data(contentsOf: csv) == before)
            #expect(try await store.loadSession(in: directory) == session)
        }
    }

    @Test func takesTheFilesFromTheSidecarNotTheLog() async throws {
        try await withTemporaryDirectory { directory in
            // Camera names are kept as they are; a ";" in one splits the
            // log's list wrongly.
            let store = CaptureStore(root: directory)
            let session = CaptureSession(name: "Run")
            let stored = try await store.store(
                [.init(cameraName: "a.ARW", data: Data([1])), .init(cameraName: "a;b.JPG", data: Data([2]))],
                baseName: nil, in: directory)
            let record = CaptureRecord(
                appVersion: "test", capturedAt: .now, session: session, files: stored,
                camera: .init(model: "ILCE-6700", lens: nil), settings: [:])
            try await store.record(record, baseName: "a", in: directory)

            let (deleted, _) = try await store.deleteLatestCapture(
                1, rewinding: session, in: directory, trash: trash(in: directory))

            #expect(deleted.files == ["a.ARW", "a;b.JPG"])
            let trashed = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "Trash").path)
            #expect(Set(trashed) == ["a.ARW", "a;b.JPG", "a.json"])
        }
    }
}

/// A fresh directory for one test, removed afterwards.
func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "CaptureCoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}
