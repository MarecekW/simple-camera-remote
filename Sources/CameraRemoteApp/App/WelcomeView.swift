import SwiftUI

/// Shown over the main window on the first launch: how to connect the
/// camera, and where the photos go.
struct WelcomeView: View {
    let settings: AppSettings
    let done: () -> Void

    /// Remembers that the welcome was seen.
    static let shownKey = "camera-remote.welcome.shown.v1"

    var body: some View {
        VStack(spacing: 20) {
            if let icon = AppInfo.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 4) {
                Text("Welcome to Simple Camera Remote")
                    .font(.title2.weight(.semibold))
                Text("Shoot with your Sony camera from your Mac.")
                    .foregroundStyle(Theme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                step(1, "Turn the camera on and connect it to your Mac with a USB cable.")
                step(2, "When the camera asks, choose **Remote Shoot (PC Remote)**. The app finds it by itself.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))

            Text("Photos are saved to **\(Self.abbreviated(settings.rootFolder))** and to the camera's card.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Get Started", action: done)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(28)
        .frame(width: 440)
        .background(Theme.background)
        .foregroundStyle(Theme.textPrimary)
        .preferredColorScheme(.dark)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `url` with the home folder as "~", without a trailing slash.
    private static func abbreviated(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let home = URL.homeDirectory.path(percentEncoded: false)
        return path.hasPrefix(home) ? "~/" + path.dropFirst(home.count) : path
    }
}
