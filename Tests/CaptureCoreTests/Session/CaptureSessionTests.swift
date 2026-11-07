import Foundation
import Testing

@testable import CaptureCore

struct CaptureSessionTests {
    @Test func advancesThroughFourSidesThenStartsTheNextLoad() {
        var session = CaptureSession(name: "P012", sample: SampleWorkflow(pallet: "P012", grade: "B"))
        var reloads: [Bool] = []
        for _ in 0..<5 {
            reloads.append(session.advanceAfterCompletedCapture())
        }
        #expect(reloads == [false, false, false, true, false])
        #expect(session.sample?.load == 2)
        #expect(session.sample?.side == 2)
        #expect(session.nextSequence == 6)
    }

    @Test func aSimpleSessionOnlyCounts() {
        var session = CaptureSession(name: "Portraits")
        let startsNewLoad = session.advanceAfterCompletedCapture()
        #expect(!startsNewLoad)
        #expect(session.nextSequence == 2)
        #expect(session.isReady)
    }

    @Test func stripIDsAreStableAcrossSides() {
        var session = CaptureSession(
            name: "P012", sample: SampleWorkflow(pallet: "P012", grade: "B", load: 3, strips: 3))
        let first = session.sample?.stripIDs
        session.advanceAfterCompletedCapture()
        #expect(first == ["P012-L03-1", "P012-L03-2", "P012-L03-3"])
        #expect(session.sample?.stripIDs == first)
    }

    @Test func aSampleSessionNeedsAGrade() {
        #expect(!CaptureSession(name: " ").isReady)
        #expect(!CaptureSession(name: "P1", sample: SampleWorkflow(pallet: "P1")).isReady)
        #expect(CaptureSession(name: "P1", sample: SampleWorkflow(pallet: "P1", grade: "B")).isReady)
    }

    @Test func aLoadCanHoldMoreStripsThanUsual() {
        let sample = SampleWorkflow(pallet: "P1", grade: "A", strips: 6)
        #expect(sample.stripIDs.last == "P1-L01-6")
        #expect(sample.stripIDs.count == 6)
    }

    @Test func savesTheStripCount() throws {
        let session = CaptureSession(name: "P1", sample: SampleWorkflow(pallet: "P1", strips: 3))
        let json = try #require(String(data: try JSONEncoder().encode(session), encoding: .utf8))
        #expect(json.contains("\"strips\":3"))
        #expect(try JSONDecoder().decode(CaptureSession.self, from: Data(json.utf8)) == session)
    }

    @Test(arguments: [("[1,3]", 3), ("[]", 5), ("[1,2,3,4,5,6,7]", 7)])
    func readsOddSlotListsAsACount(slots: String, strips: Int) throws {
        let json = #"{"pallet":"P1","grade":"A","load":1,"filledSlots":"# + slots + #","side":1}"#
        #expect(try JSONDecoder().decode(SampleWorkflow.self, from: Data(json.utf8)).strips == strips)
    }

    @Test(arguments: [(0, 1), (500, 99)])
    func clampsAStoredCount(stored: Int, strips: Int) throws {
        let json = #"{"pallet":"P1","grade":"A","load":1,"strips":"# + String(stored) + #","side":1}"#
        #expect(try JSONDecoder().decode(SampleWorkflow.self, from: Data(json.utf8)).strips == strips)
    }

    @Test func readsSessionsThatListedTheSlots() throws {
        let json = #"{"pallet":"P1","grade":"A","load":2,"filledSlots":[1,2,3,4],"side":3}"#
        #expect(
            try JSONDecoder().decode(SampleWorkflow.self, from: Data(json.utf8))
                == SampleWorkflow(pallet: "P1", grade: "A", load: 2, strips: 4, side: 3))
    }

    @Test func foldersUseTheLocalDayNearMidnight() throws {
        // 00:30 on 2 November in Bratislava is still 1 November in UTC.
        let bratislava = try #require(TimeZone(identifier: "Europe/Bratislava"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = bratislava
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 0, minute: 30)))
        let session = CaptureSession(name: "P1", sample: SampleWorkflow(pallet: "P1"))
        #expect(session.folderName(on: date, in: bratislava) == "2026-11-02_P1")
        #expect(CaptureSession.day(of: date, in: bratislava) == "2026-11-02")
    }

    @Test func foldersAreDatedForSamplesAndNamedOtherwise() throws {
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12)))
        #expect(
            CaptureSession(name: "P/12", sample: SampleWorkflow(pallet: "P/12")).folderName(on: date)
                == "2026-11-01_P-12")
        #expect(CaptureSession(name: "Studio: test").folderName(on: date) == "Studio- test")
    }
}

struct FileNameTemplateTests {
    private let session = CaptureSession(
        name: "P012", nextSequence: 47,
        sample: SampleWorkflow(pallet: "P012", grade: "B", load: 3, strips: 3, side: 2))

    @Test func rendersTheStandardTemplates() {
        #expect(
            FileNameTemplate.standardSample.fileName(for: .init(session: session, date: .now)) == "P012_B_L03_S2_0047")
        let simple = CaptureSession(name: "Portraits", nextSequence: 3)
        #expect(FileNameTemplate.standardSimple.fileName(for: .init(session: simple, date: .now)) == "Portraits_0003")
    }

    @Test func rendersSlotsDateAndTime() throws {
        let template = try FileNameTemplate("{date}-{time}_{slots}_{seq}", mode: .sampleWorkflow)
        let date = try #require(
            Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9, minute: 5, second: 7)))
        #expect(template.fileName(for: .init(session: session, date: date)) == "20261101-090507_123_47")
    }

    @Test func rejectsBadTemplates() {
        #expect(throws: FileNameTemplate.Error.missingSequence) {
            try FileNameTemplate("{pallet}_{side}", mode: .sampleWorkflow)
        }
        #expect(throws: FileNameTemplate.Error.unknownToken("strip")) {
            try FileNameTemplate("{strip}_{seq}", mode: .sampleWorkflow)
        }
        #expect(throws: FileNameTemplate.Error.unclosedBrace) {
            try FileNameTemplate("{seq}_{pallet", mode: .sampleWorkflow)
        }
        #expect(throws: FileNameTemplate.Error.invalidWidth("pallet:3")) {
            try FileNameTemplate("{pallet:3}_{seq}", mode: .sampleWorkflow)
        }
        #expect(throws: FileNameTemplate.Error.invalidWidth("seq:x")) { try FileNameTemplate("{seq:x}", mode: .simple) }
    }

    @Test func keepsSampleTokensOutOfSimpleMode() {
        #expect(throws: FileNameTemplate.Error.sampleTokenNotAvailable("grade")) {
            try FileNameTemplate("{session}_{grade}_{seq}", mode: .simple)
        }
    }

    @Test func makesUnsafeValuesSafe() throws {
        var unsafe = session
        unsafe.sample?.pallet = "../P/12:a"
        let name = FileNameTemplate.standardSample.fileName(for: .init(session: unsafe, date: .now))
        #expect(name == "-P-12-a_B_L03_S2_0047")

        let hidden = CaptureSession(name: ".hidden", nextSequence: 47)
        #expect(
            try FileNameTemplate("{session}{seq}", mode: .simple).fileName(for: .init(session: hidden, date: .now))
                == "hidden47")

        // The log joins a capture's file names with ";", one row per line.
        let listed = CaptureSession(name: "a;b\u{2028}c", nextSequence: 1)
        #expect(FileNameTemplate.standardSimple.fileName(for: .init(session: listed, date: .now)) == "a-b-c_0001")
    }

    @Test func readsTheSequenceBackFromANameItRendered() throws {
        #expect(FileNameTemplate.standardSample.sequence(in: "P012_B_L03_S2_0047") == 47)
        #expect(FileNameTemplate.standardSample.sequence(in: "P-1_2_Rustic_L10_S4_1234") == 1234)
        #expect(FileNameTemplate.standardSample.sequence(in: "DSC01135") == nil)
        #expect(FileNameTemplate.standardSimple.sequence(in: "Run_2_0003") == 3)
        let unusual = try FileNameTemplate("{seq}.{session}", mode: .simple)
        #expect(unusual.sequence(in: "12.Portraits") == 12)
        #expect(unusual.sequence(in: "12xPortraits") == nil)
    }

    @Test func previewsShowMissingValues() {
        let unfinished = CaptureSession(name: "P012", sample: SampleWorkflow(pallet: "P012"))
        #expect(
            FileNameTemplate.standardSample.preview(for: .init(session: unfinished, date: .now))
                == "P012_‹grade›_L01_S1_0001")
    }

    @Test func doesNotTruncateNumbersWiderThanThePadding() {
        var long = session
        long.nextSequence = 12345
        #expect(FileNameTemplate.standardSample.fileName(for: .init(session: long, date: .now)).hasSuffix("_12345"))
    }

    @Test func catchesUpWithACaptureRecordedAfterTheLastSave() {
        var session = CaptureSession(
            name: "P1", nextSequence: 4, sample: SampleWorkflow(pallet: "P1", grade: "A", load: 1, side: 4))
        session.catchUp(with: RecordedCapture(sequence: 4, load: 1, side: 4))
        #expect(session.nextSequence == 5)
        #expect(session.sample?.load == 2)
        #expect(session.sample?.side == 1)

        // Already past it: unchanged.
        let current = session
        session.catchUp(with: RecordedCapture(sequence: 3, load: 1, side: 3))
        #expect(session == current)
    }

    @Test func aCalibrationFrameOnlyTakesANumber() {
        var session = CaptureSession(
            name: "P1", nextSequence: 4, sample: SampleWorkflow(pallet: "P1", grade: "A", load: 1, side: 4))
        let startsNewLoad = session.advanceAfterCompletedCapture(isCalibrationFrame: true)
        #expect(!startsNewLoad)
        #expect(session.nextSequence == 5)
        #expect(session.sample?.load == 1)
        #expect(session.sample?.side == 4)

        // Caught up from the log the same way.
        var behind = CaptureSession(
            name: "P1", nextSequence: 5, sample: SampleWorkflow(pallet: "P1", grade: "A", load: 1, side: 4))
        behind.catchUp(with: RecordedCapture(sequence: 5, load: 1, side: 4, calibration: .colorChecker))
        #expect(behind.nextSequence == 6)
        #expect(behind.sample?.side == 4)
    }

    @Test func rewindsToADeletedCaptureForItsRetake() {
        // Side 4 of load 3 was shot (and the session moved to a new load
        // with another strip count), then deleted.
        var session = CaptureSession(
            name: "P1", nextSequence: 13, sample: SampleWorkflow(pallet: "P1", grade: "A", load: 4, strips: 5))
        session.rewind(toRetake: RecordedCapture(sequence: 12, load: 3, side: 4, strips: 3))
        #expect(session.nextSequence == 12)
        #expect(session.sample == SampleWorkflow(pallet: "P1", grade: "A", load: 3, strips: 3, side: 4))

        var simple = CaptureSession(name: "Portraits", nextSequence: 8)
        simple.rewind(toRetake: RecordedCapture(sequence: 7))
        #expect(simple == CaptureSession(name: "Portraits", nextSequence: 7))
    }

    @Test func aScaleMeasuredOnTheDeletedCaptureGoesWithIt() throws {
        let scale = try #require(MeasuredScale(pixels: 431, millimetres: 100, capture: "Run_0007_Ruler"))
        var session = CaptureSession(name: "Run", nextSequence: 9, measuredScale: scale)
        session.rewind(toRetake: RecordedCapture(sequence: 8, files: ["Run_0008.ARW", "Run_0008.JPG"]))
        #expect(session.measuredScale == scale)
        session.rewind(toRetake: RecordedCapture(sequence: 7, files: ["Run_0007_Ruler.ARW"]))
        #expect(session.measuredScale == nil)
    }

    @Test func namesKeepToOneLineOfTheLog() {
        #expect(CaptureSession.singleLine("  Marek\nKramár \r\n") == "Marek Kramár")
        #expect(CaptureSession.singleLine("P012") == "P012")
        #expect(CaptureSession.hasForbiddenCharacters("P0;12"))
        #expect(CaptureSession.hasForbiddenCharacters("P0\n12"))
        #expect(!CaptureSession.hasForbiddenCharacters("P 012/a"))
    }

    @Test func aLoadIsPartShotAfterItsFirstSide() {
        #expect(!SampleWorkflow(pallet: "P1", side: 1).isLoadPartShot)
        #expect(SampleWorkflow(pallet: "P1", side: 2).isLoadPartShot)
        #expect(SampleWorkflow(pallet: "P1", side: 4).isLoadPartShot)
    }

    @Test func keepsNotesAndTheMeasuredScale() throws {
        let scale = try #require(MeasuredScale(pixels: 431, millimetres: 100, capture: "P1_A_L01_S1_0001_Ruler"))
        let session = CaptureSession(name: "P1", notes: "LED panel at 45°", measuredScale: scale)
        let decoded = try JSONDecoder().decode(CaptureSession.self, from: JSONEncoder().encode(session))
        #expect(decoded == session)
    }

    @Test func readsSessionsFromBeforeNotesAndMeasuring() throws {
        let json = #"{"schemaVersion":1,"name":"P1","nextSequence":3}"#
        let session = try JSONDecoder().decode(CaptureSession.self, from: Data(json.utf8))
        #expect(session == CaptureSession(name: "P1", nextSequence: 3))
    }
}

struct CalibrationTargetTests {
    @Test func namesTheFrameAfterItsTarget() {
        #expect(CalibrationTarget.whiteCard.fileNameSuffix == "_WhiteCard")
        #expect(CalibrationTarget.removingSuffix(from: "P012_B_L03_S2_0047_ColorChecker") == "P012_B_L03_S2_0047")
        #expect(CalibrationTarget.removingSuffix(from: "P012_B_L03_S2_0047") == "P012_B_L03_S2_0047")
    }
}

struct MeasuredScaleTests {
    @Test func dividesTheMeasuredPixelsByTheKnownLength() throws {
        let pixels = MeasuredScale.pixels(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 400, y: 600))
        #expect(pixels == 500)
        let scale = try #require(MeasuredScale(pixels: pixels, millimetres: 100, capture: "a"))
        #expect(scale.pixelsPerMillimetre == 5)
    }

    @Test(arguments: [(0.0, 10.0), (500, 0), (500, -10), (500, .infinity), (.nan, 10)])
    func needsTwoRealLengths(pixels: Double, millimetres: Double) {
        #expect(MeasuredScale(pixels: pixels, millimetres: millimetres, capture: "a") == nil)
    }

    @Test func holdsOnlyAtTheFocalLengthItWasMeasuredAt() throws {
        let scale = try #require(MeasuredScale(pixels: 431, millimetres: 100, capture: "a", focalLength: 30_000))
        #expect(!scale.isStale(atFocalLength: 30_000))
        #expect(scale.isStale(atFocalLength: 45_000))
        #expect(scale.isStale(atFocalLength: nil))
        // Measured before the focal length was kept: it can't tell.
        let older = try #require(MeasuredScale(pixels: 431, millimetres: 100, capture: "a"))
        #expect(!older.isStale(atFocalLength: 45_000))
    }

    @Test func readsScalesFromBeforeTheFocalLength() throws {
        let json = #"{"pixelsPerMillimetre":4.31,"pixels":431,"millimetres":100,"capture":"a"}"#
        let scale = try JSONDecoder().decode(MeasuredScale.self, from: Data(json.utf8))
        #expect(scale.focalLength == nil)
        #expect(scale.pixelsPerMillimetre == 4.31)
    }
}
