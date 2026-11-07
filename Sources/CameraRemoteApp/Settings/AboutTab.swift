import AppKit
import SwiftUI

/// The app's icon, version and maker, any newer release, and the project's
/// page.
struct AboutTab: View {
    private var updates = UpdateChecker.shared

    var body: some View {
        VStack(spacing: 12) {
            if let icon = Self.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .accessibilityHidden(true)
            }
            Text("Simple Camera Remote")
                .font(.title2.weight(.semibold))
            Text("Version \(AppInfo.version)")
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
            Text("Free, open-source tethered shooting for Sony Alpha cameras.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
            Text("Built by @MarecekW · MIT License")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)

            VStack(spacing: 8) {
                if let update = updates.availableUpdate {
                    Text("Version \(update.version) is available.")
                        .font(.callout.weight(.semibold))
                    Button("Open Release Page") { NSWorkspace.shared.open(update.url) }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .controlSize(.large)
                        .help("Opens the new version's page on GitHub, where it can be downloaded")
                        .padding(.bottom, 6)
                }
                Link(destination: AppInfo.repositoryURL) {
                    Label("View on GitHub", systemImage: "arrow.up.right.square")
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .onAppear { updates.checkIfNeeded() }
    }

    private static let icon = AppInfo.icon
}
