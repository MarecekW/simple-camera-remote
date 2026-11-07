import SwiftUI

/// Settings (⌘, or the gear in the window's header), in the app's own look:
/// tabs on the left, their settings on the right.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let shortcuts: ShortcutBindings

    enum Tab: String, CaseIterable, Identifiable {
        case capture, checks, shortcuts, about

        var id: Self { self }

        var title: String {
            switch self {
            case .capture: "Capture"
            case .checks: "Checks"
            case .shortcuts: "Shortcuts"
            case .about: "About"
            }
        }

        /// Where the open tab is remembered.
        static let storageKey = "camera-remote.settings.tab.v1"

        var symbol: String {
            switch self {
            case .capture: "camera"
            case .checks: "exclamationmark.triangle"
            case .shortcuts: "keyboard"
            case .about: "info.circle"
            }
        }
    }

    @AppStorage(Tab.storageKey) private var tab = Tab.capture

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Tab.allCases) { item in
                    TabRow(tab: item, isSelected: item == tab) { tab = item }
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 170)
            .background(Theme.panel)
            .overlay(alignment: .trailing) { Theme.divider.frame(width: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case .capture: CaptureTab(settings: settings)
                    case .checks: ChecksTab(settings: settings)
                    case .shortcuts: ShortcutsTab(bindings: shortcuts)
                    case .about: AboutTab()
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Below the title bar only: the title bar is the sidebar's colour
            // all the way across, so the title doesn't straddle two.
            .background(Theme.background, ignoresSafeAreaEdges: [])
        }
        .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
        .background(Theme.panel)
        .frame(width: 680, height: 500)
        .foregroundStyle(Theme.textPrimary)
        .preferredColorScheme(.dark)
    }
}

/// A tab in the list: icon and title, light grey when selected.
private struct TabRow: View {
    let tab: SettingsView.Tab
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Label(tab.title, systemImage: tab.symbol)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.black : Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Layout.cornerRadius).fill(isSelected ? Theme.chipOn : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Opening

extension OpenSettingsAction {
    /// Opens Settings at `tab` — e.g. Capture for "Edit Grades…".
    @MainActor
    func callAsFunction(_ tab: SettingsView.Tab) {
        UserDefaults.standard.set(tab.rawValue, forKey: SettingsView.Tab.storageKey)
        callAsFunction()
    }
}
