import CaptureCore
import SwiftUI

/// The presets and what can be done with them: shared by the header's menu
/// and the menu bar's Presets menu, which also gives the first nine ⌘1–⌘9.
struct PresetMenuItems: View {
    let context: PresetContext
    var showsShortcuts = false

    var body: some View {
        let presets = context.presets
        if presets.presets.isEmpty {
            Text("No presets yet")
        }
        ForEach(Array(presets.presets.enumerated()), id: \.element.name) { index, preset in
            Toggle(
                preset.name,
                isOn: Binding(get: { presets.currentName == preset.name }, set: { _ in context.recall(preset) })
            )
            .keyboardShortcut(showsShortcuts && index < 9 ? KeyboardShortcut(Self.digit(index + 1)) : nil)
            .disabled(!context.canRecall)
        }
        Divider()
        Button("Save as New Preset…") { presets.naming = .saveNew }
            .disabled(!context.canSave)
        if let current = presets.currentName {
            Button("Update “\(current)” with Current Settings", action: context.updateCurrent)
                .disabled(!context.canSave)
            Button("Rename “\(current)”…") { presets.naming = .rename(current) }
                .disabled(presets.isApplying)
            Button("Delete “\(current)”…") { presets.pendingDeletion = current }
                .disabled(presets.isApplying)
        }
        Divider()
        Button("Show Presets in Finder", action: presets.showInFinder)
    }

    private static func digit(_ number: Int) -> KeyEquivalent {
        KeyEquivalent(Character(String(number)))
    }
}

/// The header's preset menu: the current preset's name, with an "Edited"
/// tag beside it once the camera or the live view no longer matches it.
/// The tag sits outside the menu: a macOS menu button shows only its
/// label's first image and text.
struct PresetButton: View {
    let context: PresetContext

    var body: some View {
        HStack(spacing: 6) {
            if context.presets.isApplying {
                ProgressView().controlSize(.small)
            } else if isModified {
                Text("Edited")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(Theme.warning.opacity(0.6)))
            }
            Menu {
                PresetMenuItems(context: context)
            } label: {
                Label(context.presets.currentName ?? "No preset", systemImage: "square.stack")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
        }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preset")
        .accessibilityValue((context.presets.currentName ?? "none") + (isModified ? ", edited" : ""))
    }

    private var isModified: Bool {
        guard let camera = context.camera else { return false }
        return context.presets.isModified(camera: camera, liveView: context.liveView)
    }

    private var help: String {
        guard let name = context.presets.currentName else {
            return "Presets: save the camera settings and live-view guides, and recall them in one go"
        }
        return isModified
            ? "Settings have changed since “\(name)” — update it, or recall it to go back"
            : "The setup matches preset “\(name)”"
    }
}

/// Names a new preset, or renames one.
struct PresetNamingSheet: View {
    let context: PresetContext
    let naming: PresetModel.Naming

    @State private var name = ""
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("e.g. Studio-1-Product", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .focused($isFocused)
                .onSubmit(confirm)
            Text(problem ?? note)
                .font(.caption)
                .foregroundStyle(problem == nil || name.isEmpty ? Theme.textSecondary : Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
        .padding(16)
        .onAppear {
            if case .rename(let oldName) = naming { name = oldName }
            isFocused = true
        }
        .onChange(of: isFocused) { _, focused in context.capture.isEditingText = focused }
        .onDisappear { context.capture.isEditingText = false }
    }

    private var oldName: String? {
        if case .rename(let oldName) = naming { return oldName }
        return nil
    }

    private var title: String {
        oldName.map { "Rename “\($0)”" } ?? "Save Preset"
    }

    private var confirmTitle: String { oldName == nil ? "Save" : "Rename" }

    private var note: String {
        oldName == nil
            ? "Keeps exposure, white balance, focus mode, area and AF point, image quality, and the live view's guides, grid and overlay. Not the zoom."
            : "The preset's file is renamed too."
    }

    private var problem: String? {
        context.presets.problem(withName: name, renaming: oldName)
    }

    private func confirm() {
        guard problem == nil else { return }
        if let oldName {
            context.presets.rename(oldName, to: name)
        } else if let camera = context.camera {
            context.presets.saveNew(named: name, camera: camera, liveView: context.liveView)
        }
        dismiss()
    }
}

extension View {
    /// The preset naming sheet and the question before deleting one.
    func presetDialogs(_ context: PresetContext) -> some View {
        modifier(PresetDialogs(context: context))
    }
}

private struct PresetDialogs: ViewModifier {
    let context: PresetContext

    func body(content: Content) -> some View {
        @Bindable var presets = context.presets
        content
            .sheet(item: $presets.naming) { naming in
                PresetNamingSheet(context: context, naming: naming)
            }
            .confirmationDialog(
                "Delete preset “\(presets.pendingDeletion ?? "")”?",
                isPresented: Binding(
                    get: { presets.pendingDeletion != nil }, set: { if !$0 { presets.pendingDeletion = nil } }),
                presenting: presets.pendingDeletion
            ) { name in
                Button("Delete", role: .destructive) { presets.delete(named: name) }
            } message: { _ in
                Text("Its file goes to the Trash.")
            }
    }
}
