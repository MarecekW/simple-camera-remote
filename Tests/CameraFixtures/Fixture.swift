import Foundation

/// Real responses captured from an A6700 (see Resources/README.md), shared by
/// the test targets.
public enum Fixture: String, CaseIterable, Sendable {
    case allProperties = "a6700-all-properties"
    case extendedDeviceInfo = "a6700-ext-device-info"
    case liveView = "a6700-live-view"

    public var data: Data {
        get throws {
            guard let url = Bundle.module.url(forResource: rawValue, withExtension: "bin", subdirectory: "Resources")
            else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try Data(contentsOf: url)
        }
    }
}
