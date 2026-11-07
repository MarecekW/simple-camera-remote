import AppKit

/// The app's version, from the bundle (set from the git tag when the .app is
/// assembled), or "dev" when run with `swift run`.
enum AppInfo {
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    static let repositoryURL = URL(string: "https://github.com/MarecekW/simple-camera-remote")!

    /// The app's folder in Application Support: presets, and files rescued
    /// when a session folder can't take them.
    static let supportDirectory = URL.applicationSupportDirectory.appending(
        path: "Simple Camera Remote", directoryHint: .isDirectory)

    /// Whether this is the .app assembled by scripts/make-app.sh, rather
    /// than the bare executable `swift run` starts.
    static let isAssembledApp = Bundle.main.bundleURL.pathExtension == "app"

    /// The app icon: the bundle's own in the assembled .app, else from the
    /// package's resources (a bare executable has no icon of its own).
    static let icon =
        isAssembledApp
        ? NSImage(named: NSImage.applicationIconName)
        : Bundle.module.url(forResource: "AppIcon", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
}
