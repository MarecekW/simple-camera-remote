import SwiftUI

// The inspector's one family of controls: every control is a box of the same
// height, fill, hairline and corner radius, and a selected value is always
// light grey with black text.  Colour is kept for the two actions, both from
// the app icon: red to shoot, orange to focus.

extension View {
    /// The box every inspector control sits in.
    func panelBox(fill: Color = Theme.panelRaised, height: CGFloat = Layout.controlHeight) -> some View {
        frame(height: height)
            .background(RoundedRectangle(cornerRadius: Layout.cornerRadius).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: Layout.cornerRadius).strokeBorder(Theme.divider, lineWidth: 1))
    }
}

/// An on/off chip: filled light grey when on, outlined when off — so its
/// state reads at a glance without competing with the action colours.  A
/// disabled chip never looks on.
struct ChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ChipLabel(isOn: configuration.isOn) { configuration.label }
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "on" : "off")
    }
}

/// A button that looks like a chip, for a toolbar action next to chips
/// (choosing an overlay, stepping the magnifier); on while `isSelected`.
struct ChipButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        ChipLabel(isOn: isSelected || configuration.isPressed) { configuration.label }
    }
}

/// The look of a chip.
private struct ChipLabel<Label: View>: View {
    let isOn: Bool
    @ViewBuilder let label: Label
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let isOn = isOn && isEnabled
        label
            .font(.callout.weight(isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? Color.black : isEnabled ? Theme.textSecondary : Theme.textTertiary)
            .padding(.horizontal, 8)
            .frame(minWidth: 24, minHeight: Layout.controlHeight)
            .background(RoundedRectangle(cornerRadius: Layout.cornerRadius).fill(isOn ? Theme.chipOn : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: Layout.cornerRadius)
                    .strokeBorder(isOn ? Theme.chipOn : Theme.divider, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}

/// The app's own button: a panel box, light grey while pressed or selected.
/// Fills the width it's given, so a row of them sits on the cell grid.
struct PanelButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        PanelButtonLabel(isPressed: configuration.isPressed || isSelected) { configuration.label }
    }
}

/// The look of `PanelButtonStyle`, also used by views that track presses
/// themselves (hold-to-zoom).
struct PanelButtonLabel<Label: View>: View {
    let isPressed: Bool
    var height = Layout.controlHeight
    /// Outlines the button (filled while pressed), for an action button (AF).
    var tint: Color?
    @ViewBuilder let label: Label
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if let tint, isEnabled {
            // Calm until used: outlined in the tint, filled while pressed.
            label
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .foregroundStyle(isPressed ? Color.white : tint)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: Layout.cornerRadius).fill(isPressed ? tint : Theme.panelRaised)
                )
                .overlay(RoundedRectangle(cornerRadius: Layout.cornerRadius).strokeBorder(tint, lineWidth: 1.5))
                .contentShape(Rectangle())
        } else {
            neutral
        }
    }

    private var neutral: some View {
        label
            .font(.callout.weight(.semibold).monospacedDigit())
            .lineLimit(1)
            // Longer labels (RAW+JPEG) shrink a little rather than clip.
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity)
            .foregroundStyle(isPressed ? Color.black : isEnabled ? Theme.textPrimary : Theme.textTertiary)
            .panelBox(fill: isPressed ? Theme.chipOn : Theme.panelRaised, height: height)
            .contentShape(Rectangle())
    }
}

/// A pop-up in a panel box: the value on the left, ⌃⌄ on the right, the
/// menu on click.  (A Menu's own label can't carry a background on macOS,
/// so the box sits behind it.)
struct PanelMenu<Items: View>: View {
    let title: String
    @ViewBuilder let items: Items

    var body: some View {
        ZStack(alignment: .trailing) {
            Menu {
                items
            } label: {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(.leading, Layout.valueInset)
            .padding(.trailing, 20)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.trailing, 7)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .panelBox()
    }
}

/// Picking one of `options` from a `PanelMenu`.
struct PanelPopUp<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        PanelMenu(title: options.first { $0.value == selection }?.title ?? "—") {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .accessibilityLabel(label)
    }
}

/// A few values side by side, the selected one light grey — the segmented
/// control of the panel family, with equal cells on the grid.
struct PanelSegmented<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: Layout.cellGap) {
            ForEach(options, id: \.value) { option in
                Button(option.title) { selection = option.value }
                    .buttonStyle(PanelButtonStyle(isSelected: option.value == selection))
                    .accessibilityAddTraits(option.value == selection ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A value between − / + (or ‹ ›) in a panel box; holding a button repeats.
/// Clicking the value can open `menu`.
struct ValueStepperBox<MenuItems: View>: View {
    let text: String
    var usesPlusMinus = false
    let step: (_ offset: Int) -> Void
    @ViewBuilder let menu: MenuItems

    var body: some View {
        HStack(spacing: 0) {
            button(usesPlusMinus ? "minus" : "chevron.left", offset: -1)
            if MenuItems.self == EmptyView.self {
                valueText.frame(maxWidth: .infinity)
            } else {
                Menu {
                    menu
                } label: {
                    valueText
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(maxWidth: .infinity)
            }
            button(usesPlusMinus ? "plus" : "chevron.right", offset: 1)
        }
        .panelBox()
    }

    private var valueText: some View {
        Text(text)
            .font(.callout.weight(.semibold).monospacedDigit())
            .foregroundStyle(Theme.textPrimary)
    }

    private func button(_ symbol: String, offset: Int) -> some View {
        Button {
            step(offset)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 28, height: Layout.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .buttonRepeatBehavior(.enabled)
        .foregroundStyle(Theme.textSecondary)
    }
}

extension ValueStepperBox where MenuItems == EmptyView {
    init(text: String, usesPlusMinus: Bool = false, step: @escaping (_ offset: Int) -> Void) {
        self.init(text: text, usesPlusMinus: usesPlusMinus, step: step) { EmptyView() }
    }
}

/// The shutter: the accent red whenever it can fire — also in an inactive
/// window, where `.borderedProminent` would turn grey and look disabled.
struct ShutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ShutterLabel(configuration: configuration)
    }

    private struct ShutterLabel: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? Color.white : Theme.textTertiary)
                .background(
                    RoundedRectangle(cornerRadius: Layout.cornerRadius)
                        .fill(isEnabled ? Theme.accent : Theme.panelRaised)
                        .brightness(configuration.isPressed ? -0.1 : 0)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Layout.cornerRadius)
                        .strokeBorder(isEnabled ? .clear : Theme.divider, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
    }
}
