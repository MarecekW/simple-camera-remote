import CaptureCore
import SwiftUI

/// The workflow, file names, operator and grades.
struct CaptureTab: View {
    @Bindable var settings: AppSettings

    @State private var sampleTemplateText = ""
    @State private var simpleTemplateText = ""
    @State private var templateErrors: [CaptureMode: String] = [:]
    @State private var gradesText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            groups
        }
        .onAppear {
            sampleTemplateText = settings.sampleTemplate.pattern
            simpleTemplateText = settings.simpleTemplate.pattern
            gradesText = settings.grades.joined(separator: ", ")
        }
        // Leaving the tab (or closing Settings) keeps what was typed, as
        // long as it's valid.
        .onDisappear {
            try? settings.setTemplate(sampleTemplateText, for: .sampleWorkflow)
            try? settings.setTemplate(simpleTemplateText, for: .simple)
            applyGrades()
        }
    }

    @ViewBuilder
    private var groups: some View {
        SettingsGroup("Workflow") {
            PanelSegmented(
                label: "Workflow", selection: $settings.captureMode,
                options: [(.sampleWorkflow, "Wood strip capture"), (.simple, "Simple")])
            SettingsNote(modeDescription)
        }
        SettingsGroup("File names") {
            switch settings.captureMode {
            case .sampleWorkflow:
                templateField($sampleTemplateText, mode: .sampleWorkflow)
            case .simple:
                SettingsRow("Names") {
                    PanelSegmented(
                        label: "Names", selection: $settings.simpleNaming,
                        options: [(.template, "From a template"), (.cameraNames, "Camera's names (DSC…)")])
                }
                if settings.simpleNaming == .template {
                    templateField($simpleTemplateText, mode: .simple)
                }
            }
        }
        SettingsGroup("Operator") {
            PanelTextField(placeholder: "Your name", text: $settings.operatorName) {}
            SettingsNote(
                "Saved with every shot: in the .json file next to its images and in the session folder's session.csv.")
        }
        SettingsGroup("Sound") {
            Toggle("Play a sound when a capture is saved or fails", isOn: $settings.playsCaptureSounds)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.callout)
            SettingsNote(
                "A saved shot plays the Glass sound. A failed shot, or a press of your Shoot key (Settings › "
                    + "Shortcuts) that couldn't take one, plays Basso.")
        }
        if settings.captureMode == .sampleWorkflow {
            SettingsGroup("Grades") {
                PanelTextField(placeholder: "A, B, C, Rustic, Waste", text: $gradesText, submit: applyGrades)
                SettingsNote(
                    "Separated by commas; Return applies. New grades can also be added from the Grade menu in the "
                        + "Session section.")
            }
        }
    }

    private var modeDescription: String {
        switch settings.captureMode {
        case .sampleWorkflow:
            "For wood strips: each pallet gets a folder per day; captures record grade, load, strips and side. The "
                + "side moves on after each shot, and after side 4 the next load starts."
        case .simple:
            "For anything else: captures go into a named session folder (today's date by default), numbered in order."
        }
    }

    @ViewBuilder
    private func templateField(_ text: Binding<String>, mode: CaptureMode) -> some View {
        SettingsRow("Template") {
            PanelTextField(placeholder: "Template", text: text, isMonospaced: true) {
                apply(text.wrappedValue, for: mode)
            }
        }
        SettingsRow("Example") {
            if let error = templateErrors[mode] {
                Text(error).foregroundStyle(Theme.failure)
            } else {
                Text(example(for: mode)).font(.callout.monospaced())
            }
        }
        SettingsNote(tokenHelp(for: mode))
    }

    private func tokenHelp(for mode: CaptureMode) -> String {
        let tokens = FileNameTemplate.Token.allCases.filter { mode == .sampleWorkflow || !$0.isSampleToken }
        return "Tokens: " + tokens.map { "{\($0.rawValue)}" }.joined(separator: " ")
            + ". {seq:04} pads the number to 4 digits (0047). {seq} is required, so every capture gets its own name. Press Return to apply."
    }

    private func example(for mode: CaptureMode) -> String {
        let session =
            switch mode {
            case .sampleWorkflow:
                CaptureSession(
                    name: "P012", nextSequence: 47,
                    sample: SampleWorkflow(pallet: "P012", grade: "B", load: 3, strips: 3, side: 2))
            case .simple:
                CaptureSession(name: "2026-11-01", nextSequence: 12)
            }
        let template = mode == .sampleWorkflow ? settings.sampleTemplate : settings.simpleTemplate
        return template.fileName(for: .init(session: session, date: .now)) + ".ARW"
    }

    private func apply(_ pattern: String, for mode: CaptureMode) {
        do throws(FileNameTemplate.Error) {
            try settings.setTemplate(pattern, for: mode)
            templateErrors[mode] = nil
        } catch {
            templateErrors[mode] =
                switch error {
                case .missingSequence: "The template must contain {seq}, so every capture gets its own name."
                case .unknownToken(let token): "Unknown token {\(token)}."
                case .unclosedBrace: "A { is never closed."
                case .invalidWidth(let token):
                    "{\(token)}: only {load}, {side} and {seq} can be padded, with 1–9 digits."
                case .sampleTokenNotAvailable(let token): "{\(token)} is only available in wood strip capture."
                }
        }
    }

    private func applyGrades() {
        let grades = gradesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            !$0.isEmpty
        }
        if !grades.isEmpty { settings.grades = grades }
    }
}
