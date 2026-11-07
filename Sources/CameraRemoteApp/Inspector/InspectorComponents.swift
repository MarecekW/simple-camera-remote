import CaptureCore
import SonyProtocol
import SonyRemote
import SwiftUI

/// A titled, collapsible group of rows, Lightroom-panel style.  Collapsed, it
/// shows a one-line summary; rare actions sit in its ⋯ menu.  Whether it's
/// open is remembered per section.
struct InspectorSection<Content: View, MenuItems: View>: View {
    let title: String
    let summary: Text?
    /// The section's advisories, counted beside the title; a click lists
    /// them.
    let advisories: [String]
    @ViewBuilder let content: Content
    @ViewBuilder let menuItems: MenuItems
    @AppStorage private var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    private static var menuSize: CGFloat { 22 }

    init(
        _ title: String, id: String, summary: Text? = nil, advisories: [String] = [], expandedByDefault: Bool = true,
        @ViewBuilder content: () -> Content, @ViewBuilder menu: () -> MenuItems
    ) {
        self.title = title
        self.summary = summary
        self.advisories = advisories
        self.content = content()
        menuItems = menu()
        _isExpanded = AppStorage(wrappedValue: expandedByDefault, "camera-remote.inspector.\(id).expanded.v2")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(reducesMotion ? nil : .easeOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10)
                        Text(title.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.8)
                            .layoutPriority(1)
                        Spacer(minLength: 8)
                        if !isExpanded, let summary {
                            summary
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Theme.textPrimary.opacity(0.75))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(accessibilityValue)
                .accessibilityAddTraits(.isHeader)

                if !advisories.isEmpty {
                    AdvisoryMark(messages: advisories, showsCount: true)
                        .padding(.leading, 4)
                }

                if MenuItems.self != EmptyView.self {
                    Menu {
                        menuItems
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: Self.menuSize, height: Self.menuSize)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    // A borderless menu draws its label in the tint colour.
                    .tint(Theme.textPrimary)
                    .fixedSize()
                    .help("More \(title.lowercased()) options")
                    .accessibilityLabel("\(title) options")
                } else {
                    // Keeps every summary's right edge in line.
                    Color.clear.frame(width: Self.menuSize, height: Self.menuSize)
                }
            }
            .padding(.horizontal, Layout.inspectorPadding)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    content
                }
                .padding(.horizontal, Layout.inspectorPadding)
                .padding(.bottom, 12)
            }
            Theme.divider.frame(height: 1)
        }
    }

    /// Collapsed, the summary is read after the state, as it's shown.
    private var accessibilityValue: Text {
        guard !isExpanded else { return Text("expanded") }
        return summary.map { Text("collapsed, ") + $0 } ?? Text("collapsed")
    }
}

extension InspectorSection where MenuItems == EmptyView {
    init(
        _ title: String, id: String, summary: Text? = nil, advisories: [String] = [], expandedByDefault: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title, id: id, summary: summary, advisories: advisories, expandedByDefault: expandedByDefault,
            content: content
        ) {
            EmptyView()
        }
    }
}

/// A label on the left, its value or control on the right.
struct InspectorRow<Content: View>: View {
    let label: String
    /// Shown as an amber mark beside the label that explains it on a click.
    let advisory: String?
    @ViewBuilder let content: Content

    init(_ label: String, advisory: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.advisory = advisory
        self.content = content()
    }

    var body: some View {
        HStack(spacing: Layout.labelGap) {
            HStack(spacing: 4) {
                Text(label)
                    .foregroundStyle(advisory == nil ? Theme.textSecondary : Theme.warning)
                if let advisory {
                    AdvisoryMark(messages: [advisory])
                }
            }
            .frame(width: Layout.inspectorLabelWidth, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .frame(minHeight: Layout.controlHeight)
    }
}

/// A plain value in a row, starting where text inside a control's box does.
struct InspectorValue: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .padding(.leading, Layout.valueInset)
    }
}

/// An amber warning sign that says what's wrong when clicked (and on
/// hover): advisories are explained where they're shown.
struct AdvisoryMark: View {
    let messages: [String]
    var showsCount = false

    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "exclamationmark.triangle.fill")
                if showsCount { Text("\(messages.count)") }
            }
            .font(.system(size: showsCount ? 10 : 9, weight: .semibold))
            .foregroundStyle(Theme.warning)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(messages.joined(separator: "\n"))
        .accessibilityLabel("Warning")
        .accessibilityValue(messages.joined(separator: " "))
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(messages.count == 1 ? "Warning" : "\(messages.count) warnings")
                    .font(.headline)
                ForEach(messages, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(AdvisoryLabelStyle())
                }
                Text("A suggestion for this type of work; captures still work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(width: 300, alignment: .leading)
        }
    }
}

extension [Advisory] {
    /// What's advised about `setting`, for its row; nil if nothing is.
    func message(for setting: CaptureRecord.Setting) -> String? {
        let messages = filter { $0.setting == setting }.map(\.message)
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    /// The messages about any of `settings`, for a section's header.
    func messages(for settings: Set<CaptureRecord.Setting>) -> [String] {
        filter { $0.setting.map(settings.contains) == true }.map(\.message)
    }

    /// The messages of one kind, for advisories about no single setting.
    func messages(of kind: Advisory.Kind) -> [String] {
        filter { $0.kind == kind }.map(\.message)
    }
}

/// An advisory line: the amber sign, then text that wraps.
private struct AdvisoryLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.foregroundStyle(Theme.warning)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

/// Acts while held down — autofocus, zoom — and lets go on release, or when
/// the press is cancelled or the view goes away.
struct HoldButton<Label: View>: View {
    /// What VoiceOver calls it, e.g. "Zoom wide"; `help` is its hint.
    let title: String
    let help: String
    var height = Layout.controlHeight
    var tint: Color?
    let action: (_ isPressed: Bool) -> Void
    @ViewBuilder let label: Label

    @State private var isPressed = false

    var body: some View {
        PanelButtonLabel(isPressed: isPressed, height: height, tint: tint) { label }
            // SwiftUI's press tracking: down, then up or cancelled — the
            // release is never missed, however short the click.
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: .infinity) {
            } onPressingChanged: { pressing in
                isPressed = pressing
                action(pressing)
            }
            .onDisappear {
                if isPressed {
                    isPressed = false
                    action(false)
                }
            }
            .help(help)
            .accessibilityLabel(title)
            .accessibilityHint(help)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                action(true)
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    action(false)
                }
            }
    }
}

/// A camera value with ‹ › to step through what the camera accepts (holding
/// repeats) and a menu of all of them on the value itself — the control of
/// Capture One's and Sony Remote's exposure panels.  Read-only, with a lock,
/// when the camera or the exposure lock owns the setting.
struct CameraValueStepper: View {
    let label: String
    let code: SonyPropertyCode
    let camera: SonyCamera
    let controls: CameraControls
    /// Keyboard hint for the tooltip, e.g. "S / ⇧S".
    var shortcut: String?
    /// Explicit − / + instead of ‹ › (exposure compensation).
    var usesPlusMinus = false

    /// Why this setting could make captures inconsistent, if it could.
    var advisory: String?

    var body: some View {
        InspectorRow(label, advisory: advisory) {
            if let value = controls.value(of: code, on: camera) {
                let options = controls.choices(for: code, on: camera)
                if options.count > 1 {
                    ValueStepperBox(text: display(value), usesPlusMinus: usesPlusMinus) { offset in
                        controls.step(code, by: offset, on: camera)
                    } menu: {
                        Picker(
                            label, selection: Binding(get: { value }, set: { controls.set(code, to: $0, on: camera) })
                        ) {
                            ForEach(options, id: \.self) { Text(display($0)).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    .help("Click the value for all of them" + (shortcut.map { " · keys \($0)" } ?? ""))
                } else {
                    LockedValue(text: display(value), reason: reason, isCentred: true)
                }
            } else {
                Text("—").foregroundStyle(Theme.textSecondary)
                    .help("The camera doesn't offer this setting.")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(controls.value(of: code, on: camera).map(display) ?? "unavailable")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: controls.step(code, by: 1, on: camera)
            case .decrement: controls.step(code, by: -1, on: camera)
            @unknown default: break
            }
        }
    }

    private func display(_ value: PTPValue) -> String {
        CameraSettingFormat.display(value, of: code)
    }

    private var reason: String {
        if controls.isLocked(code) { return LockedValue.exposureLockReason }
        return camera.properties[code].map(LockedValue.reason) ?? ""
    }
}

/// One of a few camera values side by side — exposure mode, focus mode, file
/// format.  Only values the camera accepts now are offered; anything else the
/// camera is set to shows as text, with `fallback` to get back.
struct CameraSegmentedPicker: View {
    let label: String
    let code: SonyPropertyCode
    let camera: SonyCamera
    let controls: CameraControls
    /// The values this picker can offer, in display order.
    let values: [PTPValue]
    /// Offered when the camera is set to a value outside `values`.
    var fallback: (title: String, value: PTPValue)?

    /// Why this setting could make captures inconsistent, if it could.
    var advisory: String?

    var body: some View {
        InspectorRow(label, advisory: advisory) { picker }
    }

    @ViewBuilder
    private var picker: some View {
        if let value = controls.value(of: code, on: camera) {
            let choices = controls.choices(for: code, on: camera)
            let offered = values.filter(choices.contains)
            if values.contains(value), offered.count > 1 {
                PanelSegmented(
                    label: label,
                    selection: Binding(get: { value }, set: { controls.set(code, to: $0, on: camera) }),
                    options: offered.map { ($0, CameraSettingFormat.display($0, of: code)) })
            } else if !values.contains(value), let fallback, choices.contains(fallback.value) {
                HStack(spacing: Layout.cellGap) {
                    InspectorValue(CameraSettingFormat.display(value, of: code))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(fallback.title) { controls.set(code, to: fallback.value, on: camera) }
                        .buttonStyle(PanelButtonStyle())
                        .frame(width: Layout.cell)
                }
            } else {
                LockedValue(
                    text: CameraSettingFormat.display(value, of: code),
                    reason: controls.isLocked(code)
                        ? LockedValue.exposureLockReason
                        : camera.properties[code].map(LockedValue.reason) ?? "")
            }
        } else {
            Text("—").foregroundStyle(Theme.textSecondary)
        }
    }
}

/// A camera setting picked from a pop-up of the values the camera accepts
/// right now, with their names.
struct CameraPropertyRow: View {
    let label: String
    let code: SonyPropertyCode
    let camera: SonyCamera
    let controls: CameraControls

    /// Why this setting could make captures inconsistent, if it could.
    var advisory: String?

    var body: some View {
        InspectorRow(label, advisory: advisory) {
            if let value = controls.value(of: code, on: camera) {
                let options = controls.choices(for: code, on: camera)
                if options.count > 1 {
                    PanelPopUp(
                        label: label,
                        selection: Binding(get: { value }, set: { controls.set(code, to: $0, on: camera) }),
                        options: options.map { ($0, CameraSettingFormat.display($0, of: code)) })
                } else {
                    LockedValue(
                        text: CameraSettingFormat.display(value, of: code),
                        reason: camera.properties[code].map(LockedValue.reason) ?? "")
                }
            } else {
                Text("—").foregroundStyle(Theme.textSecondary)
                    .help("The camera doesn't offer this setting.")
            }
        }
    }
}

/// A value the app can't change right now: the control's box without its
/// buttons, a lock, and the reason on hover.
struct LockedValue: View {
    static let exposureLockReason = "Exposure is locked — unlock it in the Exposure ⋯ menu or with ⌥⌘L."

    let text: String
    let reason: String
    /// Centred like a stepper's value, else leading like a pop-up's.
    var isCentred = false

    var body: some View {
        HStack(spacing: 5) {
            if !isCentred { Spacer().frame(width: Layout.valueInset - 5) }
            Text(text)
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Image(systemName: "lock.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
            if !isCentred { Spacer(minLength: 0) }
        }
        .font(isCentred ? .callout.weight(.semibold) : .callout)
        .frame(maxWidth: .infinity)
        .panelBox(fill: .clear)
        .help(reason)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityHint(reason)
    }

    static func reason(_ descriptor: PropertyDescriptor) -> String {
        switch descriptor.availability {
        case .displayOnly: "Set by the camera — its mode dial or exposure mode decides this."
        case .disabled: "Not available in the camera's current mode."
        case .enabled: descriptor.isWritable ? "The camera offers no other value right now." : "Read-only."
        }
    }
}
