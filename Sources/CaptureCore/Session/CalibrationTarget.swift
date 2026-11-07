/// What a calibration frame shows, instead of strips: a reference for colour,
/// white balance or scale.  A tag on one capture, recorded
/// in its sidecar and the session log and added to its file name, so the
/// frame is never taken for a sample.
public enum CalibrationTarget: String, CaseIterable, Codable, Sendable {
    case colorChecker = "ColorChecker"
    case whiteCard = "WhiteCard"
    case ruler = "Ruler"

    /// How the target is named for the user.
    public var label: String {
        switch self {
        case .colorChecker: "ColorChecker"
        case .whiteCard: "White card"
        case .ruler: "Ruler"
        }
    }

    /// Added to the template's name, e.g. `P012_B_L03_S2_0047_ColorChecker`.
    public var fileNameSuffix: String { "_" + rawValue }

    /// `fileName` (without extension) without a calibration suffix, so a
    /// calibration frame's number is found like any other's.
    public static func removingSuffix(from fileName: String) -> String {
        guard let target = allCases.first(where: { fileName.hasSuffix($0.fileNameSuffix) }) else { return fileName }
        return String(fileName.dropLast(target.fileNameSuffix.count))
    }
}
