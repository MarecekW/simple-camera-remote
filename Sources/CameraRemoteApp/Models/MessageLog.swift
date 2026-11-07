import Foundation
import Observation

/// What the app has to tell the user — capture results, failures, notes —
/// shown one at a time in the window's bottom bar, with recent ones kept for
/// its history popover.
@MainActor
@Observable
final class MessageLog {
    struct Entry: Identifiable, Equatable {
        enum Kind { case info, success, warning, failure }

        let id = UUID()
        let date = Date.now
        let kind: Kind
        let text: String
    }

    /// How many entries the history keeps.
    private static let historyLimit = 20

    /// The newest entry, until it's dismissed.
    private(set) var current: Entry?
    /// Newest first.
    private(set) var history: [Entry] = []

    func post(_ kind: Entry.Kind, _ text: String) {
        let entry = Entry(kind: kind, text: text)
        current = entry
        history.insert(entry, at: 0)
        history = Array(history.prefix(Self.historyLimit))
    }

    /// Clears the bar; the history keeps the entry.
    func dismiss() {
        current = nil
    }
}
