// swift-tools-version: 6.2
import PackageDescription

// Zero warnings: every Swift target fails the build on one.
let strictSwiftSettings: [SwiftSetting] = [.treatAllWarnings(as: .error)]

/// ImageCaptureCore only shows cameras to processes with a bundle identity.
/// Embedding an Info.plist gives a bare executable one, so `swift run` works.
/// (unsafeFlags are fine: this is a root package, never a dependency.)
func embeddedInfoPlist(_ path: String) -> LinkerSetting {
    .unsafeFlags([
        "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
        "-Xlinker", "\(Context.packageDirectory)/\(path)",
    ])
}

let package = Package(
    name: "SimpleCameraRemote",
    platforms: [.macOS(.v14)],
    products: [
        // Executables — product names stay kebab-case (Unix-style binary
        // names) while target/folder names are PascalCase (Swift convention).
        .executable(name: "camera-remote-cli", targets: ["CameraRemoteCLI"]),
        .executable(name: "camera-remote-app", targets: ["CameraRemoteApp"]),
    ],
    targets: [
        .target(name: "SonyProtocol", path: "Sources/SonyProtocol", swiftSettings: strictSwiftSettings),
        .target(name: "CaptureCore", path: "Sources/CaptureCore", swiftSettings: strictSwiftSettings),
        .target(
            name: "SonyRemote",
            dependencies: ["SonyProtocol"],
            path: "Sources/SonyRemote",
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "CameraRemoteCLI",
            dependencies: ["SonyRemote", "SonyProtocol"],
            path: "Sources/CameraRemoteCLI",
            exclude: ["Info.plist"],
            swiftSettings: strictSwiftSettings,
            linkerSettings: [embeddedInfoPlist("Sources/CameraRemoteCLI/Info.plist")]
        ),
        .executableTarget(
            name: "CameraRemoteApp",
            dependencies: ["CaptureCore", "SonyRemote"],
            path: "Sources/CameraRemoteApp",
            exclude: ["Info.plist"],
            resources: [.copy("Resources/AppIcon.png")],
            swiftSettings: strictSwiftSettings,
            linkerSettings: [embeddedInfoPlist("Sources/CameraRemoteApp/Info.plist")]
        ),
        // Real camera responses, shared by the test targets.
        .target(
            name: "CameraFixtures",
            path: "Tests/CameraFixtures",
            resources: [.copy("Resources")],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "CaptureCoreTests",
            dependencies: ["CaptureCore"],
            path: "Tests/CaptureCoreTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "SonyProtocolTests",
            dependencies: ["SonyProtocol", "CameraFixtures"],
            path: "Tests/SonyProtocolTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "SonyRemoteTests",
            dependencies: ["SonyRemote", "SonyProtocol", "CameraFixtures"],
            path: "Tests/SonyRemoteTests",
            swiftSettings: strictSwiftSettings
        ),
    ]
)
