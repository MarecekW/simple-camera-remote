import Foundation
import Observation

/// Keys the user chose for the main actions — e.g. a wireless numpad's + to
/// shoot and − to focus, so the camera can be worked from the subject.
/// Remembered between launches; set in Settings → Shortcuts.
@MainActor
@Observable
final class ShortcutBindings {
    enum Action: String, CaseIterable, Identifiable, Codable {
        case shoot, focus, focusNearer, focusFarther, magnify, review, nextSide, previousSide, nextLoad
        case grid, centre, histogram, peaking, rulers

        var id: Self { self }

        /// Shown in Settings under "Live view" rather than "Camera and
        /// workflow".
        var isLiveViewOption: Bool {
            switch self {
            case .grid, .centre, .histogram, .peaking, .rulers: true
            default: false
            }
        }

        /// Acts again on the key's repeats while it's held.
        var repeatsWhileHeld: Bool { self == .focusNearer || self == .focusFarther }

        var title: String {
            switch self {
            case .shoot: "Shoot"
            case .focus: "Focus"
            case .focusNearer: "Focus nearer"
            case .focusFarther: "Focus farther"
            case .magnify: "Focus magnifier"
            case .review: "Review"
            case .nextSide: "Next side"
            case .previousSide: "Previous side"
            case .nextLoad: "Next load"
            case .grid: "Grid"
            case .centre: "Centre cross"
            case .histogram: "Histogram"
            case .peaking: "Focus peaking"
            case .rulers: "Rulers"
            }
        }

        var detail: String {
            switch self {
            case .shoot: "Takes a picture, like the Shoot button."
            case .focus:
                "Holds a half press, like the AF button: in AF modes it focuses; in MF it doesn't focus, it only "
                    + "steadies the image."
            case .focusNearer, .focusFarther:
                "Manual focus (MF or DMF): a tap moves one small step; held, it keeps moving in medium steps."
            case .magnify: "Steps through the camera's magnifications, then off."
            case .review: "Shows or hides the last capture at full resolution."
            case .nextSide: "Wood strip capture only: moves to the next side of the load."
            case .previousSide: "Wood strip capture only: moves back to the previous side."
            case .nextLoad: "Wood strip capture only: starts the next load at side 1."
            case .grid: "Shows or hides the rule-of-thirds grid, as G does."
            case .centre: "Shows or hides the centre cross, as C does."
            case .histogram: "Shows or hides the live histogram, as H does."
            case .peaking: "Turns focus peaking on or off, as P does."
            case .rulers: "Shows or hides the rulers and guides, as U does."
            }
        }
    }

    /// A physical key, told apart by its key code: the keypad's + is not the
    /// main keyboard's +.  Pressed with no modifiers.
    struct Key: Codable, Equatable, Sendable {
        let keyCode: UInt16
        /// How it's shown, e.g. "Keypad +".
        let name: String
    }

    /// Bound keys by action; an action without one has no key.
    private(set) var keys: [Action: Key] {
        didSet { save() }
    }
    /// The action whose key is being recorded in Settings; while set, no
    /// shortcut fires, so the key pressed is only recorded.
    var recordingAction: Action?

    @ObservationIgnored private let defaults: UserDefaults
    private static let storageKey = "camera-remote.shortcuts.v1"

    /// + to shoot and − to focus, / to magnify and * to review: the keypad's
    /// keys that stay the same with Num Lock on or off.
    static let defaultKeys: [Action: Key] = [
        .shoot: Key(keyCode: KeyCodes.keypadPlus, name: "Keypad +"),
        .focus: Key(keyCode: KeyCodes.keypadMinus, name: "Keypad −"),
        .magnify: Key(keyCode: KeyCodes.keypadDivide, name: "Keypad /"),
        .review: Key(keyCode: KeyCodes.keypadMultiply, name: "Keypad *"),
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
            let stored = try? JSONDecoder().decode([String: Key].self, from: data)
        {
            keys = Dictionary(
                uniqueKeysWithValues: stored.compactMap { name, key in Action(rawValue: name).map { ($0, key) } })
        } else {
            keys = Self.defaultKeys
        }
    }

    func action(for keyCode: UInt16) -> Action? {
        keys.first { $0.value.keyCode == keyCode }?.key
    }

    /// Binds `key` to `action`, taking it from any action that had it.
    func bind(_ key: Key, to action: Action) {
        var updated = keys.filter { $0.value.keyCode != key.keyCode }
        updated[action] = key
        keys = updated
    }

    func clear(_ action: Action) {
        keys[action] = nil
    }

    func restoreDefaults() {
        keys = Self.defaultKeys
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: keys.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

// MARK: - Keys

extension ShortcutBindings {
    /// Key codes (Carbon `kVK_…`) that need a name of their own.
    enum KeyCodes {
        static let keypadPlus: UInt16 = 0x45
        static let keypadMinus: UInt16 = 0x4E
        static let keypadMultiply: UInt16 = 0x43
        static let keypadDivide: UInt16 = 0x4B
        static let escape: UInt16 = 0x35
        static let returnKey: UInt16 = 0x24
        static let space: UInt16 = 0x31
        static let tab: UInt16 = 0x30
        static let keypadEnter: UInt16 = 0x4C
    }

    private static let keyNames: [UInt16: String] = [
        // The keypad.
        0x52: "Keypad 0", 0x53: "Keypad 1", 0x54: "Keypad 2", 0x55: "Keypad 3", 0x56: "Keypad 4",
        0x57: "Keypad 5", 0x58: "Keypad 6", 0x59: "Keypad 7", 0x5B: "Keypad 8", 0x5C: "Keypad 9",
        0x41: "Keypad .", KeyCodes.keypadMultiply: "Keypad *", KeyCodes.keypadPlus: "Keypad +",
        KeyCodes.keypadDivide: "Keypad /", KeyCodes.keypadMinus: "Keypad −", 0x51: "Keypad =",
        KeyCodes.keypadEnter: "Keypad Enter", 0x47: "Num Lock",
        // Keys without a printable character.
        KeyCodes.tab: "Tab", 0x33: "Delete", 0x75: "Forward Delete", KeyCodes.returnKey: "Return",
        KeyCodes.escape: "Esc", KeyCodes.space: "Space",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x73: "Home", 0x77: "End", 0x74: "Page Up", 0x79: "Page Down",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
    ]

    /// The keys the app already uses on their own (zoom, exposure steps,
    /// sides, the live-view toolbar, Space to shoot), Esc that cancels
    /// recording, Return and Enter that confirm dialogs, and Tab that moves
    /// between controls: never bound.
    private static let reservedCharacters: Set<String> = [
        "w", "t", "a", "s", "f", "i", "e", "[", "]", "{", "}",
        "g", "c", "h", "u", "o", "p", "m", "r", "z", "k",
    ]
    private static let reservedKeyCodes: Set<UInt16> = [
        KeyCodes.escape, KeyCodes.returnKey, KeyCodes.keypadEnter, KeyCodes.space, KeyCodes.tab,
    ]

    /// The key with `keyCode`, typing `characters`, named for showing; nil
    /// when the app keeps that key for itself.
    static func key(keyCode: UInt16, characters: String?) -> Key? {
        if let name = keyNames[keyCode] {
            return reservedKeyCodes.contains(keyCode) ? nil : Key(keyCode: keyCode, name: name)
        }
        guard let characters = characters?.lowercased(), !characters.isEmpty,
            !reservedCharacters.contains(characters),
            characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return Key(keyCode: keyCode, name: characters.uppercased())
    }
}
