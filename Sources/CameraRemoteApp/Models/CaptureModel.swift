import AppKit
import CaptureCore
import Foundation
import Observation
import SonyProtocol
import SonyRemote

/// Taking pictures: the session (pallet, grade, load, side — or a simple
/// named session), what blocks the shutter, and storing each capture with
/// its record.
///
/// No capture is mislabelled or lost: the session can't change while a
/// capture runs, files that don't make a complete capture go to
/// `unassigned/`, and the session only advances once a capture is stored and
/// recorded.
@MainActor
@Observable
final class CaptureModel {
    /// Shooting needs this much free space on the Mac: room for a good
    /// number of shots (`typicalCaptureSize` each).
    private static let minimumFreeSpace: Int64 = 1_000_000_000
    /// About what an A6700 RAW+JPEG pair takes, for estimates before the
    /// session's first capture.
    private static let typicalCaptureSize = 45_000_000

    private(set) var session: CaptureSession
    /// A capture is being taken, or the last one deleted: the session can't
    /// change meanwhile.
    private(set) var isCapturing = false
    private(set) var isOpeningSession = false
    /// The newest capture of this session.
    private(set) var lastCapture: LastCapture?
    /// Marks the next capture as a calibration frame; applies to that one
    /// capture only (nil once it's saved).
    var nextCalibration: CalibrationTarget?
    /// Set while a text field is being edited, so single-key shortcuts
    /// (Space to shoot, G for the grid…) type instead of firing.
    var isEditingText = false
    /// The session name as typed but not confirmed yet; shooting waits for
    /// it, so a photo can't be saved under the previous pallet.
    var pendingSessionName: String?
    /// A typed session name that already has captures, waiting for the user
    /// to continue it or choose another name.
    private(set) var existingSession: ExistingSession?
    /// Bumped to ask the inspector to focus the session-name field.
    private(set) var sessionNameFocusRequest = 0
    /// Why the session last asked for couldn't be opened; the shutter stays
    /// blocked, so nothing is saved under the previous session meanwhile.
    private(set) var openFailure: String?

    @ObservationIgnored private let camera: CameraModel
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let messages: MessageLog
    /// Whether autofocus or a live-view click holds the shutter now; the
    /// shutter waits for it.  Set by the app.
    @ObservationIgnored var isShutterInUse: @MainActor () -> Bool = { false }
    /// Whether a preset is being recalled; captures wait for its settings.
    @ObservationIgnored var isRecallingPreset: @MainActor () -> Bool = { false }
    @ObservationIgnored private var store: CaptureStore
    /// The open session's folder.
    private(set) var sessionDirectory: URL?
    /// Space left on the Mac, as last measured.
    private(set) var freeSpace: Int64?
    /// The settings of the session's first capture, as displayed; captures
    /// should keep to them (nil before the first).
    private(set) var firstCaptureSettings: [CaptureRecord.Setting: String]?
    /// What the session's folder takes on disk, as last measured.
    private(set) var sessionSize: Int64?
    @ObservationIgnored private var captureFinished: [CheckedContinuation<Void, Never>] = []
    /// Identifies the newest `openSession` call; an older one finishing
    /// later must not win.
    @ObservationIgnored private var openGeneration = 0
    /// Set when a capture didn't complete: its files may still be on their
    /// way, and must not be taken for the next capture's.
    @ObservationIgnored private var mayHaveLateFiles = false
    /// The latest save of a manual change to the session; the next save, a
    /// capture's included, waits for it.
    @ObservationIgnored private var sessionSave: Task<Void, Never>?

    init(camera: CameraModel, settings: AppSettings, messages: MessageLog) {
        self.camera = camera
        self.settings = settings
        self.messages = messages
        store = CaptureStore(root: settings.rootFolder)
        session = Self.emptySession(for: settings.captureMode)
    }

    // MARK: - Session

    /// Opens the session called `name` — the pallet in the sample workflow.
    /// Resumes it if it exists; a pallet continued from an earlier day keeps
    /// counting loads (so strip IDs stay unique) and keeps its grade, while a
    /// new pallet needs its grade chosen.  `reload` reopens an unchanged
    /// name, e.g. after the save folder changed.
    func openSession(named name: String, reload: Bool = false, asksBeforeResuming: Bool = false) async {
        let name = CaptureSession.singleLine(name)
        guard !isCapturing else { return }
        openGeneration += 1
        let generation = openGeneration
        // A question about an earlier name no longer applies.
        existingSession = nil
        guard reload || name != session.name || (sessionDirectory == nil && !name.isEmpty) else {
            finishOpening(failure: nil)
            return
        }
        guard !CaptureSession.hasForbiddenCharacters(name) else {
            finishOpening(failure: "A session name can't contain “;”.")
            return
        }
        isOpeningSession = true
        if store.root != settings.rootFolder { store = CaptureStore(root: settings.rootFolder) }
        guard !name.isEmpty else {
            session = Self.emptySession(for: settings.captureMode)
            sessionDirectory = nil
            lastCapture = nil
            firstCaptureSettings = nil
            sessionSize = nil
            finishOpening(failure: nil)
            return
        }

        var opened = CaptureSession(name: name)
        if settings.captureMode == .sampleWorkflow {
            // The rig's slots stay as they were; the grade is the pallet's own.
            let strips = session.sample?.strips ?? SampleWorkflow.defaultStrips
            opened.sample = SampleWorkflow(pallet: name, strips: strips)
        }
        let directory = store.directory(for: opened, on: .now)
        var notes: [String] = []
        var isContinuingAnEarlierDay = false
        var lastRecorded: RecordedCapture?
        var firstSettings: [CaptureRecord.Setting: String]?
        do {
            if let saved = try await store.loadSession(in: directory), (saved.sample == nil) == (opened.sample == nil) {
                opened = saved
                notes.append("Resumed \(name)\(Self.position(of: saved)).")
            } else if opened.sample != nil,
                let earlier = try await store.latestEarlierSession(ofPallet: name, before: directory),
                var sample = earlier.sample
            {
                // A new day for this pallet: carry on where it stood, with
                // the same grade.  A load left half-shot goes on with the
                // same side, so its strips keep their IDs (Next Load starts
                // afresh); a new load takes the rig's current strip count.
                if sample.side == 1 { sample.strips = opened.sample?.strips ?? sample.strips }
                opened.sample = sample
                isContinuingAnEarlierDay = true
                notes.append("Continuing \(name)\(Self.position(of: opened)).")
            }
            // The log is the authority on what was taken, should the
            // session file have fallen behind.
            if let recorded = try await store.lastRecordedCapture(in: directory) {
                opened.catchUp(with: recorded)
                lastRecorded = recorded
            }
            // Files a crash left without a record keep their names: number
            // on after them, so the next capture's name is free.
            if let template = settings.activeTemplate,
                let highest = try await store.highestSequence(in: directory, namedBy: template)
            {
                opened.nextSequence = max(opened.nextSequence, highest + 1)
            }
            firstSettings = try await store.firstRecordedSettings(in: directory)
            // A typed name that already has captures may be a typo for a new
            // pallet: ask before adding to it.
            if asksBeforeResuming,
                let detail = Self.existingCaptures(of: opened, continuingAnEarlierDay: isContinuingAnEarlierDay)
            {
                guard generation == openGeneration else { return }
                existingSession = ExistingSession(name: name, detail: detail)
                isOpeningSession = false
                return
            }
            let recovered = try await store.recoverIncomingFiles(in: directory)
            if recovered > 0 {
                notes.append("\(recovered) file(s) from an interrupted save were moved to “unassigned”.")
            }
        } catch {
            guard generation == openGeneration else { return }
            finishOpening(failure: "Couldn't open \(name): \(error.localizedDescription)")
            return
        }
        guard generation == openGeneration else { return }
        if directory != sessionDirectory { lastCapture = lastRecorded.flatMap { Self.lastCapture($0, in: directory) } }
        session = opened
        sessionDirectory = directory
        firstCaptureSettings = firstSettings
        settings.setLastSessionName(name, for: settings.captureMode)
        measureFreeSpace()
        measureSessionSize()
        if !notes.isEmpty { messages.post(.info, notes.joined(separator: " ")) }
        finishOpening(failure: nil)
    }

    /// Opens the session the user was asked about.
    func continueExistingSession() async {
        guard let existing = existingSession else { return }
        existingSession = nil
        await openSession(named: existing.name, reload: true)
    }

    /// Drops the name the user was asked about and lets them type another.
    func chooseAnotherName() {
        existingSession = nil
        finishOpening(failure: nil)
        focusSessionName()
    }

    /// What's already been captured under `opened`'s name, for the
    /// question before resuming it; nil when nothing has.
    private static func existingCaptures(of opened: CaptureSession, continuingAnEarlierDay: Bool) -> String? {
        if continuingAnEarlierDay, let sample = opened.sample {
            let position = sample.side == 1 ? "load \(sample.load)" : "load \(sample.load), side \(sample.side)"
            return "It was shot on an earlier day (grade \(sample.grade)). Continuing goes on with \(position) "
                + "in today's folder."
        }
        let captures = opened.nextSequence - 1
        guard captures > 0 else { return nil }
        let count = captures == 1 ? "1 capture" : "\(captures) captures"
        guard let sample = opened.sample else { return "It already has \(count)." }
        // Wood strip sessions are per day; simple ones aren't.
        return "It already has \(count) today — next is load \(sample.load), side \(sample.side)."
    }

    /// The dock's last capture, from the session log and its sidecar — so
    /// it shows after a relaunch too; nil if its files have gone.
    private static func lastCapture(_ recorded: RecordedCapture, in directory: URL) -> LastCapture? {
        let sidecar = recorded.sidecar(in: directory)
        // Recorded as the camera sent it, e.g. "0x9088" (`CameraSettingFormat.raw`).
        let focalLength = sidecar?.settings[CaptureRecord.Setting.focalLength.rawValue].flatMap { setting in
            setting.raw.hasPrefix("0x") ? UInt32(setting.raw.dropFirst(2), radix: 16) : nil
        }
        let files = (sidecar?.files.map(\.name) ?? recorded.files).map { directory.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let first = files.first, let capturedAt = recorded.capturedAt else { return nil }
        let bytes = files.reduce(0) { total, file in
            total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return LastCapture(
            name: first.deletingPathExtension().lastPathComponent, sequence: recorded.sequence, files: files,
            bytes: bytes, capturedAt: capturedAt, focalLength: focalLength)
    }

    private func finishOpening(failure: String?) {
        isOpeningSession = false
        pendingSessionName = nil
        openFailure = failure
    }

    /// Opens the mode's last session — at launch, and when the capture mode
    /// changes (after any running capture, which belongs to the old mode).
    func captureModeChanged() async {
        await waitUntilIdle()
        let mode = settings.captureMode
        session = Self.emptySession(for: mode)
        sessionDirectory = nil
        let name = settings.lastSessionName(for: mode) ?? (mode == .simple ? CaptureSession.day(of: .now) : "")
        await openSession(named: name)
    }

    func setGrade(_ grade: String) { updateSample { $0.grade = grade } }
    func setLoad(_ load: Int) { updateSample { $0.load = max(1, load) } }
    func setSide(_ side: Int) { updateSample { $0.side = min(max(1, side), SampleWorkflow.sidesPerLoad) } }

    func setStrips(_ strips: Int) {
        updateSample { $0.strips = min(max(1, strips), SampleWorkflow.maximumStrips) }
    }

    /// Sets the session's notes; blank text removes them.
    func setNotes(_ notes: String) {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        updateSession { $0.notes = trimmed.isEmpty ? nil : trimmed }
    }

    /// Keeps `scale` for this session (nil forgets it); later captures
    /// record it while the lens stays at the focal length it was measured at.
    func setMeasuredScale(_ scale: MeasuredScale?) {
        guard !isCapturing else { return }
        updateSession { $0.measuredScale = scale }
        guard let scale else { return }
        messages.post(
            .success,
            "Measured \(scale.pixelsPerMillimetre.formatted(.number.precision(.fractionLength(2)))) px/mm on "
                + "\(scale.capture); later captures in this session record it.")
    }

    /// Ends the current load early (e.g. a side wasn't needed): the next
    /// capture is side 1 of the next load.
    func startNextLoad() {
        updateSample { sample in
            sample.load += 1
            sample.side = 1
        }
    }

    /// Moves the keyboard focus to the session-name (pallet) field.
    func focusSessionName() { sessionNameFocusRequest += 1 }

    /// The next capture's file name without extension, or nil when files
    /// keep the camera's names.
    var nextFileName: String? {
        settings.activeTemplate.map { $0.fileName(for: .init(session: session, date: .now)) + calibrationSuffix }
    }

    /// The next file name for display, with `‹grade›`-style placeholders for
    /// what's still missing; nil when files keep the camera's names.
    var nextFilePreview: String? {
        settings.activeTemplate.map { $0.preview(for: .init(session: session, date: .now)) + calibrationSuffix }
    }

    /// A calibration frame's name says so, so it's never taken for a sample.
    private var calibrationSuffix: String { nextCalibration?.fileNameSuffix ?? "" }

    /// Captures taken in this session so far.
    var captureCount: Int { session.nextSequence - 1 }

    /// About how many more captures fit on the Mac, judged by the last one
    /// (or a typical RAW+JPEG pair before the first).
    var capturesThatFit: Int? {
        guard let free = freeSpace else { return nil }
        let perCapture = Int64(lastCapture?.bytes ?? Self.typicalCaptureSize)
        return Int(max(free - Self.minimumFreeSpace, 0) / max(perCapture, 1))
    }

    // MARK: - Shooting

    /// Why the shutter is blocked, or nil when a capture can be taken.
    var blockedReason: String? { shutterBlock?.message }

    /// What keeps the shutter from firing, first things first; nil when a
    /// capture can be taken.
    var shutterBlock: ShutterBlock? {
        guard let sonyCamera = camera.camera, camera.state == .connected else { return .notConnected }
        if isCapturing { return .capturing }
        if isShutterInUse() { return .focusing }
        if isRecallingPreset() { return .recallingPreset }
        if isOpeningSession { return .openingSession }
        if let openFailure { return .openFailed(openFailure) }
        let isSample = session.sample != nil
        if let pending = pendingSessionName, CaptureSession.singleLine(pending) != session.name {
            return .unconfirmedName(isPallet: isSample)
        }
        if session.name.isEmpty { return .missingName(isPallet: isSample) }
        if session.sample?.grade.isEmpty == true { return .missingGrade }
        if let issue = settingIssues.first { return .settingIssue(issue.message, isFixable: canFixSettings) }
        if sonyCamera.properties[.mediaSlot1RemainingShots]?.currentValue.integerValue == 0 { return .cardFull }
        if let freeSpace, freeSpace < Self.minimumFreeSpace { return .diskFull }
        return nil
    }

    var settingIssues: [CaptureSettingIssue] {
        camera.camera.map { CaptureSettings.issues(in: $0.properties) } ?? []
    }

    var canFixSettings: Bool { settingIssues.contains { $0.isFixable } }

    /// Fixes the setting issues through the camera's own lists, in the order
    /// they must land, and says which it couldn't.
    func fixSettings() async {
        guard let sonyCamera = camera.camera else { return }
        let skipped: [(issue: CaptureSettingIssue, skip: SonyCamera.SettingSkip)]
        do {
            skipped = try await sonyCamera.fixCaptureSettings()
        } catch {
            messages.post(.failure, "Couldn't change the settings: \(error.localizedDescription)")
            return
        }
        guard !skipped.isEmpty else { return }
        for (issue, skip) in skipped {
            Log.capture.warning(
                "fixing \(issue.code, privacy: .public) skipped: \(String(describing: skip), privacy: .public)")
        }
        messages.post(
            .warning,
            "Couldn't fix every setting — change these on the camera: "
                + skipped.map(\.issue.message).joined(separator: " "))
    }

    /// Takes a picture, stores its files under the template name with a
    /// record, and moves the session on.  The session only advances once
    /// every file arrived and was stored and recorded; whatever doesn't make
    /// it is kept in `unassigned/`.
    func shoot() async {
        guard blockedReason == nil, let sonyCamera = camera.camera, let directory = sessionDirectory else { return }
        isCapturing = true
        defer { finishCapturing() }
        // Set once the capture is stored: every way out before then failed.
        var sound = CaptureSound.failed
        defer { playSound(sound) }
        let shot = session
        let calibration = nextCalibration
        let baseName = nextFileName
        var notes: [String] = []

        // Images still in camera memory belong to an earlier, interrupted
        // capture: kept apart, file by file, before this one is taken.  After
        // an incomplete capture, its files get a moment to arrive first.
        do {
            if mayHaveLateFiles { try await Task.sleep(for: Self.lateFileAllowance) }
            let leftovers = try await sonyCamera.drainWaitingImages { file in
                try await self.keepApart(CaptureStore.IncomingFile(file), in: directory)
            }
            mayHaveLateFiles = false
            if leftovers > 0 { notes.append("\(leftovers) leftover image(s) were saved in “unassigned”.") }
        } catch {
            messages.post(.failure, "Couldn't clear the camera's memory: \(error.localizedDescription).")
            return
        }

        // A magnified view is for checking focus, not for shooting: end it
        // first, so the camera shoots from its normal state.
        if sonyCamera.magnification != nil {
            try? await sonyCamera.endMagnification()
        }
        // The settings as the shutter fires, not after the transfer (a dial
        // or the zoom may move meanwhile).
        do {
            try await sonyCamera.refreshProperties()
        } catch {
            Log.capture.error("refresh before capture failed: \(error.localizedDescription, privacy: .public)")
            notes.append("The settings couldn't be read before the shot; the recorded ones may be out of date.")
        }
        let cameraRecord = CaptureRecord.Camera(
            model: sonyCamera.name, serialNumber: sonyCamera.serialNumber, lens: sonyCamera.lensName)
        let recordedSettings = CameraSettingFormat.recordedSettings(from: sonyCamera.properties)
        let advisories = CameraSettingFormat.advisories(
            from: sonyCamera.properties, mainsFrequency: settings.mainsFrequency,
            shootingType: settings.shootingType, firstCapture: firstCaptureSettings)
        let scale = ResolutionEstimate(camera: sonyCamera, settings: settings).map(CaptureRecord.Scale.init)
        let focalLength = sonyCamera.focalLength
        let capturedAt = Date.now

        let files: [CapturedFile]
        do {
            files = try await sonyCamera.capture(
                expectedFiles: CaptureSettings.expectedFileCount(in: sonyCamera.properties))
        } catch let error as CaptureError {
            // Without focus the shutter never fired: nothing can come late.
            mayHaveLateFiles = error.reason != .noFocus
            let kept = await keepApart(error.files.map(CaptureStore.IncomingFile.init), in: directory)
            messages.post(.failure, Self.describe(error, kept: kept) + " " + retakeHint)
            return
        } catch {
            mayHaveLateFiles = true
            messages.post(.failure, "The shutter didn't fire: \(error.localizedDescription).")
            return
        }

        // On failure the store moves the capture's files to unassigned/, and
        // hands back any it couldn't, for the rescue folder.
        let stored: [CaptureRecord.File]
        let recordName: String
        do {
            let incoming = files.map(CaptureStore.IncomingFile.init)
            stored = try await store.store(incoming, baseName: baseName, in: directory)
            // With camera names, the sidecar takes the first file's name.
            recordName = baseName ?? stored.first.map { ($0.name as NSString).deletingPathExtension } ?? "capture"
            var record = CaptureRecord(
                appVersion: AppInfo.version, capturedAt: capturedAt, session: shot, files: stored,
                camera: cameraRecord, settings: recordedSettings, advisories: advisories, scale: scale,
                calibration: calibration, operatorName: operatorName)
            // A scale measured at another focal length doesn't hold here.
            if record.measuredScale?.isStale(atFocalLength: focalLength) == true { record.measuredScale = nil }
            try await store.record(record, baseName: recordName, in: directory)
        } catch let failure as CaptureStore.StoreFailure where !failure.unkept.isEmpty {
            let kept = await keepApart(failure.unkept, in: directory)
            let lost = failure.unkept.count - kept
            messages.post(
                .failure,
                "Couldn't save the capture (\(failure.localizedDescription)); its files are in “unassigned” "
                    + (lost == 0 ? "or the rescue folder. " : "— \(lost) could not be saved at all. ") + retakeHint)
            return
        } catch {
            messages.post(
                .failure,
                "Couldn't save the capture (\(error.localizedDescription)); its files are in “unassigned”. "
                    + retakeHint)
            return
        }

        sound = .saved
        lastCapture = LastCapture(
            name: recordName, sequence: shot.nextSequence, files: stored.map { directory.appending(path: $0.name) },
            bytes: stored.reduce(0) { $0 + $1.bytes }, capturedAt: capturedAt, focalLength: focalLength)
        measureFreeSpace()
        measureSessionSize()
        if firstCaptureSettings == nil { firstCaptureSettings = recordedSettings.mapValues(\.display) }
        nextCalibration = nil
        var next = shot
        let startsNewLoad = next.advanceAfterCompletedCapture(isCalibrationFrame: calibration != nil)
        session = next
        do {
            await sessionSave?.value
            try await store.saveSession(next, in: directory)
        } catch {
            // The capture is safe; reopening the session re-derives the
            // sequence from the log.
            messages.post(
                .warning,
                "Saved \(recordName), but the session's progress couldn't be saved: "
                    + "\(error.localizedDescription).")
            return
        }
        notes.insert(
            Self.savedMessage(
                recordName, next: next, previous: shot, startsNewLoad: startsNewLoad, calibration: calibration),
            at: 0)
        messages.post(startsNewLoad || notes.count > 1 ? .warning : .success, notes.joined(separator: " "))
    }

    /// How a capture ended, heard from across the room.
    enum CaptureSound {
        case saved, failed

        fileprivate var name: NSSound.Name {
            switch self {
            case .saved: "Glass"
            case .failed: "Basso"
            }
        }
    }

    /// Plays `sound` unless sounds are off in Settings.
    func playSound(_ sound: CaptureSound) {
        guard settings.playsCaptureSounds else { return }
        NSSound(named: sound.name)?.play()
    }

    private var retakeHint: String { session.sample == nil ? "Shoot again." : "Retake this side." }

    /// Who's shooting, for the record (on one line, as the log's rows are);
    /// nil when not set.
    private var operatorName: String? {
        let name = CaptureSession.singleLine(settings.operatorName)
        return name.isEmpty ? nil : name
    }

    /// Deletes the newest capture from the Mac — its files and sidecar to
    /// the Trash, its row from the session log — and steps the session back,
    /// so the retake gets the same name, load, side and strips (and is a
    /// calibration frame again if it was one, unless the next shot already
    /// has a tag).  `sequence` is the capture the user confirmed: if another
    /// has been taken since, nothing is deleted.  The card keeps its copy.
    func deleteLastCapture(_ sequence: Int) async {
        guard !isCapturing, !isOpeningSession, let last = lastCapture, let directory = sessionDirectory else {
            return
        }
        guard last.sequence == sequence else {
            messages.post(.warning, "Nothing was deleted: \(last.name) was taken after the one you confirmed.")
            return
        }
        isCapturing = true
        defer { finishCapturing() }
        // A manual change still being saved must not land after the rewind.
        await sessionSave?.value
        let hadMeasuredScale = session.measuredScale != nil
        let deleted: RecordedCapture
        do {
            // Saves the rewound session with the rest, all or nothing.
            let result = try await store.deleteLatestCapture(sequence, rewinding: session, in: directory)
            deleted = result.deleted
            session = result.session
        } catch {
            messages.post(.failure, "Couldn't delete \(last.name): \(error.localizedDescription).")
            return
        }
        // The dock and review go back to the capture before; the drift
        // baseline goes if the session's first capture was the one deleted.
        let previous = (try? await store.lastRecordedCapture(in: directory)) ?? nil
        lastCapture = previous.flatMap { Self.lastCapture($0, in: directory) }
        firstCaptureSettings = (try? await store.firstRecordedSettings(in: directory)) ?? nil
        if nextCalibration == nil { nextCalibration = deleted.calibration }
        measureFreeSpace()
        measureSessionSize()
        var message = "Deleted \(last.name); the card copy is kept."
        if let sample = session.sample { message += " Next: load \(sample.load), side \(sample.side)." }
        if hadMeasuredScale && session.measuredScale == nil { message += " The scale measured on it is cleared." }
        messages.post(.info, message)
    }

    /// Returns once no capture is running — so quitting or switching modes
    /// doesn't cut a capture short.
    func waitUntilIdle() async {
        guard isCapturing else { return }
        await withCheckedContinuation { captureFinished.append($0) }
    }

    private func finishCapturing() {
        isCapturing = false
        for waiter in captureFinished { waiter.resume() }
        captureFinished = []
    }

    // MARK: - Private

    /// How long the files of an incomplete capture get to arrive before the
    /// next capture; a long exposure or slow card write can make them late.
    private static let lateFileAllowance: Duration = .seconds(3)

    /// The last resort for files that couldn't be stored in their session.
    private static let rescueFolder = AppInfo.supportDirectory.appending(path: "Rescued", directoryHint: .isDirectory)

    private static func emptySession(for mode: CaptureMode) -> CaptureSession {
        CaptureSession(name: "", sample: mode == .sampleWorkflow ? SampleWorkflow(pallet: "") : nil)
    }

    private static func position(of session: CaptureSession) -> String {
        guard let sample = session.sample else { return " at capture \(session.nextSequence)" }
        return ": load \(sample.load), side \(sample.side)"
    }

    /// Changes the sample workflow and saves it.
    private func updateSample(_ change: (inout SampleWorkflow) -> Void) {
        guard session.sample != nil else { return }
        updateSession { session in
            if var sample = session.sample {
                change(&sample)
                session.sample = sample
            }
        }
    }

    /// Changes the session and saves it — never while a capture runs, which
    /// would name or record it with the change.
    private func updateSession(_ change: (inout CaptureSession) -> Void) {
        guard !isCapturing else { return }
        change(&session)
        guard let directory = sessionDirectory else { return }
        let state = session
        let store = store
        // After the previous save, so an older state never lands last.
        let previous = sessionSave
        sessionSave = Task {
            await previous?.value
            do {
                try await store.saveSession(state, in: directory)
            } catch {
                messages.post(.warning, "Couldn't save the session: \(error.localizedDescription).")
            }
        }
    }

    /// Stores the files of an incomplete or unsaved capture apart; returns
    /// how many were kept.
    private func keepApart(_ files: [CaptureStore.IncomingFile], in directory: URL) async -> Int {
        var kept = 0
        for file in files {
            do {
                try await keepApart(file, in: directory)
                kept += 1
            } catch {
                Log.capture.error(
                    "lost \(file.cameraName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return kept
    }

    /// Stores a file that belongs to no capture in the session's
    /// `unassigned/` or, failing that, the rescue folder — downloading it
    /// removed it from the camera's memory, so this is its only copy.
    private func keepApart(_ file: CaptureStore.IncomingFile, in directory: URL) async throws {
        do {
            _ = try await store.storeUnassigned(file, in: directory)
        } catch {
            Log.capture.error("unassigned/ failed, rescuing: \(error.localizedDescription, privacy: .public)")
            _ = try await CaptureStore(root: Self.rescueFolder).storeUnassigned(file, in: Self.rescueFolder)
        }
    }

    private static func describe(_ error: CaptureError, kept: Int) -> String {
        let reason =
            switch error.reason {
            case .noFocus: "The camera couldn't focus — give the subject some contrast, or use MF."
            case .timedOut: "Not every file arrived — the camera may not have fired."
            case .transferFailed(let details): "The transfer broke off (\(details))."
            case .mixedCaptures: "The camera sent files from different captures."
            }
        guard !error.files.isEmpty else { return reason }
        return reason + " \(kept) of \(error.files.count) received file(s) kept in “unassigned”."
    }

    private static func savedMessage(
        _ name: String, next: CaptureSession, previous: CaptureSession, startsNewLoad: Bool,
        calibration: CalibrationTarget?
    ) -> String {
        guard let sample = next.sample else { return "Saved \(name)." }
        if let calibration {
            return "Saved \(name) (\(calibration.label)). Side \(sample.side) of load \(sample.load) is still next."
        }
        if startsNewLoad, let finished = previous.sample {
            return
                "Saved \(name). Load \(finished.load) is done — put the next strips on the rig for load \(sample.load)."
        }
        return "Saved \(name). Turn the strips to side \(sample.side)."
    }

    /// Re-measures the session folder in the background: when a session
    /// opens and after each capture.
    private func measureSessionSize() {
        guard let directory = sessionDirectory else {
            sessionSize = nil
            return
        }
        Task {
            let size = await store.totalSize(of: directory)
            if directory == sessionDirectory { sessionSize = size }
        }
    }

    /// Re-reads the space left on the Mac: when a session opens and after
    /// each capture, the moments it changes because of this app.
    /// Measured at the save folder itself, or its nearest existing parent
    /// before the first capture creates it — a folder on another volume
    /// counts that volume's space.
    private func measureFreeSpace() {
        var folder = settings.rootFolder
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 {
            folder = folder.deletingLastPathComponent()
        }
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        freeSpace = values?.volumeAvailableCapacityForImportantUsage
    }
}

extension CaptureStore.IncomingFile {
    /// A file as the camera sent it.
    init(_ file: CapturedFile) {
        self.init(cameraName: file.info.filename, data: file.data)
    }
}
