/// Why the shutter can't fire, and what fixes it.
enum ShutterBlock: Equatable {
    case notConnected
    case capturing
    case focusing
    case recallingPreset
    case openingSession
    case openFailed(String)
    case unconfirmedName(isPallet: Bool)
    case missingName(isPallet: Bool)
    case missingGrade
    case settingIssue(String, isFixable: Bool)
    case cardFull
    case diskFull

    /// The one-click fix offered with it.
    enum Fix { case enterName, fixSettings }

    var message: String {
        switch self {
        case .notConnected: "The camera isn't connected."
        case .capturing: "Capturing…"
        case .focusing: "Focusing…"
        case .recallingPreset: "Recalling preset…"
        case .openingSession: "Opening the session…"
        case .openFailed(let reason): reason
        case .unconfirmedName(let isPallet): "Press Return to confirm the \(isPallet ? "pallet" : "session name")."
        case .missingName(let isPallet): "Enter the \(isPallet ? "pallet" : "session name")."
        case .missingGrade: "Choose the grade."
        case .settingIssue(let message, _): message
        case .cardFull: "The camera's card is full."
        case .diskFull: "The Mac's disk is almost full."
        }
    }

    var fix: Fix? {
        switch self {
        case .openFailed, .unconfirmedName, .missingName: .enterName
        case .settingIssue(_, let isFixable): isFixable ? .fixSettings : nil
        case .notConnected, .capturing, .focusing, .recallingPreset, .openingSession, .missingGrade, .cardFull,
            .diskFull:
            nil
        }
    }
}
