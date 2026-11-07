import AppKit
import CaptureCore
import SwiftUI

/// What's in front of the camera: the session (the pallet, in the sample
/// workflow) and, for samples, grade, load and strips.  The workflow itself
/// is switched in the ⋯ menu, which also holds the session's notes; the side
/// is set in the footer, next to the shutter.
struct SessionSection: View {
    let capture: CaptureModel
    @Bindable var settings: AppSettings

    /// A grade or strip count for the load on the rig.
    private enum LoadChange {
        case grade(String)
        case strips(Int)
    }

    @State private var nameText = ""
    @State private var isNewGradeShown = false
    @State private var isNotesShown = false
    /// A change to a part-shot load, waiting for the user's OK.
    @State private var pendingChange: LoadChange?
    /// The load whose part-shot change was confirmed: one confirmation
    /// covers the rest of that load (e.g. stepping strips 5 → 2).
    @State private var confirmedLoad: String?
    @FocusState private var nameFocused: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        InspectorSection("Session", id: "session", summary: Text(summary)) {
            InspectorRow(capture.session.sample == nil ? "Session" : "Pallet") {
                TextField(capture.session.sample == nil ? "Name" : "e.g. P012", text: $nameText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, Layout.valueInset)
                    .panelBox(fill: Theme.background)
                    .focused($nameFocused)
                    .onSubmit { nameFocused = false }
                    // Required: outlined until filled in.
                    .overlay(
                        RoundedRectangle(cornerRadius: Layout.cornerRadius)
                            .strokeBorder(Theme.warning, lineWidth: 1)
                            .opacity(capture.session.name.isEmpty ? 1 : 0)
                            .allowsHitTesting(false)
                    )
                    .disabled(capture.isCapturing)
                    .help("Return or a click elsewhere confirms it")
            }
            if let sample = capture.session.sample {
                InspectorRow("Grade") {
                    PanelMenu(title: sample.grade.isEmpty ? "Choose…" : sample.grade) {
                        Picker("Grade", selection: Binding(get: { sample.grade }, set: { request(.grade($0)) })) {
                            ForEach(gradeChoices(current: sample.grade), id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        Divider()
                        Button("New Grade…") { isNewGradeShown = true }
                        Button("Edit Grades…") { openSettings(.capture) }
                    }
                    .accessibilityLabel("Grade")
                    .disabled(capture.isCapturing)
                    .popover(isPresented: $isNewGradeShown, arrowEdge: .bottom) {
                        NewGrade(capture: capture, settings: settings) { grade in
                            isNewGradeShown = false
                            request(.grade(grade))
                        }
                    }
                }
                InspectorRow("Load") {
                    ValueStepperBox(text: "\(sample.load)", usesPlusMinus: true) { offset in
                        capture.setLoad(sample.load + offset)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Load")
                    .accessibilityValue("\(sample.load)")
                    .accessibilityAdjustableAction { direction in
                        capture.setLoad(sample.load + (direction == .increment ? 1 : -1))
                    }
                    .disabled(capture.isCapturing)
                }
                InspectorRow("Strips") {
                    // The rig fills from the bottom, so only the count matters.
                    ValueStepperBox(text: "\(sample.strips)", usesPlusMinus: true) { offset in
                        request(.strips(sample.strips + offset))
                    }
                    .help("Strips on the rig, counted from the bottom")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Strips")
                    .accessibilityValue("\(sample.strips)")
                    .accessibilityAdjustableAction { direction in
                        request(.strips(sample.strips + (direction == .increment ? 1 : -1)))
                    }
                    .disabled(capture.isCapturing)
                }
            }
        } menu: {
            Picker("Workflow", selection: $settings.captureMode) {
                Text("Wood strip capture — pallet, grade, load, side").tag(CaptureMode.sampleWorkflow)
                Text("Simple — a named session").tag(CaptureMode.simple)
            }
            .pickerStyle(.inline)
            .disabled(capture.isCapturing)
            if settings.captureMode == .simple {
                Picker("File Names", selection: $settings.simpleNaming) {
                    Text("From a Template").tag(AppSettings.SimpleNaming.template)
                    Text("Camera's Names (DSC…)").tag(AppSettings.SimpleNaming.cameraNames)
                }
                .pickerStyle(.inline)
            }
            Divider()
            Button("Session Notes…") { isNotesShown = true }
                .disabled(capture.sessionDirectory == nil || capture.isCapturing)
            if settings.captureMode == .sampleWorkflow {
                Button("Edit Grades…") { openSettings(.capture) }
            }
            Button("Show Session Folder") {
                if let folder = capture.sessionDirectory { showInFinder(folder) }
            }
            .disabled(capture.sessionDirectory == nil)
        }
        .onAppear { nameText = capture.session.name }
        .onChange(of: capture.sessionNameFocusRequest) { nameFocused = true }
        .onChange(of: capture.session.name) { _, name in
            if !nameFocused { nameText = name }
        }
        .onChange(of: nameText) { _, text in
            if nameFocused { capture.pendingSessionName = text }
        }
        .onDisappear { capture.isEditingText = false }
        .onChange(of: nameFocused) { _, focused in
            capture.isEditingText = focused
            if !focused {
                let name = nameText
                Task { await capture.openSession(named: name, asksBeforeResuming: true) }
            }
        }
        .alert(
            "“\(capture.existingSession?.name ?? "")” already exists",
            isPresented: Binding(get: { capture.existingSession != nil }, set: { _ in }),
            presenting: capture.existingSession
        ) { existing in
            Button("Continue “\(existing.name)”") { Task { await capture.continueExistingSession() } }
            Button("Choose Another Name", role: .cancel) { capture.chooseAnotherName() }
        } message: { existing in
            Text(existing.detail + " Continue it, or choose another name?")
        }
        .confirmationDialog(
            "Load \(capture.session.sample?.load ?? 0) is part-shot",
            isPresented: Binding(get: { pendingChange != nil }, set: { if !$0 { pendingChange = nil } }),
            presenting: pendingChange
        ) { change in
            Button(confirmTitle(change), role: .destructive) {
                confirmedLoad = loadKey
                apply(change)
            }
        } message: { change in
            Text(partShotNote(change))
        }
        .sheet(isPresented: $isNotesShown) {
            SessionNotesSheet(capture: capture)
        }
    }

    /// Changes the grade or strips — after asking, while the load on the rig
    /// is part-shot: its earlier sides were recorded with the old values.
    private func request(_ change: LoadChange) {
        guard let sample = capture.session.sample else { return }
        let change =
            switch change {
            case .grade: change
            case .strips(let strips): LoadChange.strips(min(max(1, strips), SampleWorkflow.maximumStrips))
            }
        let isDifferent =
            switch change {
            case .grade(let grade): grade != sample.grade
            case .strips(let strips): strips != sample.strips
            }
        guard isDifferent else { return }
        if sample.isLoadPartShot, confirmedLoad != loadKey {
            pendingChange = change
        } else {
            apply(change)
        }
    }

    /// The pallet and load on the rig, e.g. "P012 · 3".
    private var loadKey: String? {
        capture.session.sample.map { "\(capture.session.name) · \($0.load)" }
    }

    private func apply(_ change: LoadChange) {
        switch change {
        case .grade(let grade): capture.setGrade(grade)
        case .strips(let strips): capture.setStrips(strips)
        }
    }

    private func confirmTitle(_ change: LoadChange) -> String {
        switch change {
        case .grade(let grade): "Change Grade to \(grade)"
        case .strips(let strips): "Change to \(strips) Strip\(strips == 1 ? "" : "s")"
        }
    }

    /// What the earlier sides were recorded with, and why changing it now
    /// mislabels the rest of the load.
    private func partShotNote(_ change: LoadChange) -> String {
        guard let sample = capture.session.sample else { return "" }
        let shot = sample.side == 2 ? "Side 1 was" : "Sides 1–\(sample.side - 1) were"
        switch change {
        case .grade:
            return "\(shot) recorded as grade \(sample.grade). Changing the grade now labels the load's "
                + "remaining sides differently from its earlier ones."
        case .strips:
            return "\(shot) recorded with \(sample.strips) strips. Changing the count now gives the remaining "
                + "sides strip IDs and labels that don't match the earlier sides'. For new strips, use Next Load."
        }
    }

    /// The configured grades, plus the pallet's own if it's not among them
    /// (a session from before the list changed).
    private func gradeChoices(current: String) -> [String] {
        current.isEmpty || settings.grades.contains(current) ? settings.grades : settings.grades + [current]
    }

    private var summary: String {
        guard let sample = capture.session.sample else { return capture.session.name }
        let grade = sample.grade.isEmpty ? "no grade" : sample.grade
        return "\(capture.session.name.isEmpty ? "No pallet" : capture.session.name) · \(grade) · L\(sample.load)"
    }
}

/// Typing a grade that isn't in the list yet: it's used for the pallet and
/// added to the list for next time.
private struct NewGrade: View {
    let capture: CaptureModel
    let settings: AppSettings
    /// Uses the grade for the pallet.
    let choose: (String) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New grade").font(.headline)
            HStack(spacing: 6) {
                TextField("e.g. Premium", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .focused($isFocused)
                    .onSubmit(add)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(grade.isEmpty)
            }
            Text("Also added to the list in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .onAppear { isFocused = true }
        .onChange(of: isFocused) { _, focused in capture.isEditingText = focused }
        .onDisappear { capture.isEditingText = false }
    }

    private var grade: String { text.trimmingCharacters(in: .whitespaces) }

    private func add() {
        guard !grade.isEmpty else { return }
        if !settings.grades.contains(grade) { settings.grades.append(grade) }
        choose(grade)
    }
}

/// The session's notes — the rig, the light, anything unusual — recorded
/// with every capture from now on.
private struct SessionNotesSheet: View {
    let capture: CaptureModel

    @State private var text = ""
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notes for “\(capture.session.name)”").font(.headline)
            TextEditor(text: $text)
                .font(.callout)
                .frame(width: 360, height: 120)
                .focused($isFocused)
                .overlay(RoundedRectangle(cornerRadius: Layout.cornerRadius).strokeBorder(Theme.divider, lineWidth: 1))
            Text("Saved with the session and recorded in the sidecar of every capture from now on.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    capture.setNotes(text)
                    dismiss()
                }
                // Return types a new line.
                .keyboardShortcut(.return, modifiers: .command)
                .help("Save (⌘Return)")
            }
        }
        .padding(16)
        .onAppear {
            text = capture.session.notes ?? ""
            isFocused = true
        }
        .onChange(of: isFocused) { _, focused in capture.isEditingText = focused }
        .onDisappear { capture.isEditingText = false }
    }
}

/// Where captures go and what they're called: the folder, the name
/// template and the next number.  Changing them is in the ⋯ menu.
struct OutputSection: View {
    let settings: AppSettings
    let capture: CaptureModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        InspectorSection("Output", id: "output", summary: Text(folder.lastPathComponent)) {
            InspectorRow("Folder") {
                Button {
                    showInFinder(folder)
                } label: {
                    Text(abbreviatedPath(folder))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Layout.valueInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show in Finder — \(folder.path(percentEncoded: false))")
            }
            InspectorRow("Names") {
                Text(settings.activeTemplate?.pattern ?? "Camera's names (DSC…)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Layout.valueInset)
                    .help(settings.activeTemplate?.pattern ?? "Files keep the camera's names")
            }
            InspectorRow("Size") {
                InspectorValue(sizeText)
                    .font(.callout.monospacedDigit())
                    .help("What this session's folder takes on disk")
            }
            InspectorRow("Counter") {
                InspectorValue(String(format: "%04d", capture.session.nextSequence))
                    .font(.callout.monospacedDigit())
                    .help("The next capture's number in this session")
            }
        } menu: {
            Button("Change Folder…", action: chooseFolder)
                .disabled(capture.isCapturing)
            Button("Show in Finder") { showInFinder(folder) }
            Divider()
            Button("Edit Name Templates…") { openSettings(.capture) }
        }
    }

    /// "12 captures · 540 MB".
    private var sizeText: String {
        guard capture.captureCount > 0 else { return "No captures yet" }
        let captures = capture.captureCount == 1 ? "1 capture" : "\(capture.captureCount) captures"
        guard let size = capture.sessionSize else { return captures }
        return captures + " · " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// The session's folder once open, else the save folder.
    private var folder: URL { capture.sessionDirectory ?? settings.rootFolder }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.rootFolder
        panel.prompt = "Save Here"
        panel.message = "Choose the folder captures are saved in. Each session gets its own folder inside it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.rootFolder = url
        Task { await capture.openSession(named: capture.session.name, reload: true) }
    }
}

/// `url` with the home folder as "~".
private func abbreviatedPath(_ url: URL) -> String {
    let path = url.path(percentEncoded: false)
    let home = URL.homeDirectory.path(percentEncoded: false)
    return path.hasPrefix(home) ? "~/" + path.dropFirst(home.count) : path
}

/// Shows `folder` in Finder, creating it first: before the first capture it
/// may not exist yet.
private func showInFinder(_ folder: URL) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    NSWorkspace.shared.activateFileViewerSelecting([folder])
}
