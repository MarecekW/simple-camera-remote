import SwiftUI

/// The app's palette: dark and neutral, so the live view and captured
/// images are judged against grey, not colour.
enum Theme {
    /// Main window background (~#171717).
    static let background = Color(white: 0.09)
    /// Panels: status bar, toolbar, inspector (~#222).
    static let panel = Color(white: 0.14)
    /// Buttons drawn by the app (zoom), a step above the panel.
    static let panelRaised = Color(white: 0.17)
    static let divider = Color(white: 0.22)
    static let textPrimary = Color(white: 0.95)
    static let textSecondary = Color(white: 0.55)
    /// Hints and lock glyphs, quieter than secondary text.
    static let textTertiary = Color(white: 0.38)
    /// The app icon's red, for the shutter only.
    static let accent = Color(red: 0.84, green: 0.24, blue: 0.22)
    /// Focusing (AF-ON): orange, a neighbour of the shutter's red.
    static let focus = Color(red: 0.93, green: 0.55, blue: 0.20)
    /// The fill of switched-on chips: neutral, so many of them stay calm.
    static let chipOn = Color(white: 0.80)
    /// The inspector's footer: darker than the panel, so it reads as a dock.
    static let dock = Color(white: 0.11)
    static let success = Color(red: 0.30, green: 0.80, blue: 0.40)
    static let warning = Color(red: 0.95, green: 0.70, blue: 0.25)
    static let failure = Color(red: 0.95, green: 0.30, blue: 0.25)
    /// Positioning guides, cyan as in Photoshop: visible on wood and grey.
    static let guide = Color(red: 0.20, green: 0.85, blue: 0.95)
}

/// Fixed sizes shared by the window's regions.
enum Layout {
    static let statusBarHeight: CGFloat = 36
    static let toolbarHeight: CGFloat = 32
    static let messageBarHeight: CGFloat = 26
    static let inspectorWidth: CGFloat = 320
    static let inspectorPadding: CGFloat = 12
    static let inspectorLabelWidth: CGFloat = 76
    /// Gap between a row's label and its control.
    static let labelGap: CGFloat = 8
    /// The width of a row's control column (212).
    static let controlWidth = inspectorWidth - 2 * inspectorPadding - inspectorLabelWidth - labelGap
    /// Controls split into cells sit on a four-column grid, so every row's
    /// gaps line up (cells of 50).
    static let cellGap: CGFloat = 4
    static let cell = (controlWidth - 3 * cellGap) / 4
    /// Every control in the inspector is this tall.
    static let controlHeight: CGFloat = 22
    static let cornerRadius: CGFloat = 5
    /// Plain values start where the text inside a control's box starts.
    static let valueInset: CGFloat = 8
    static let minimumWindowSize = CGSize(width: 1100, height: 700)
}
