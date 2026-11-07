import Foundation

/// How captured files are named, e.g. `{pallet}_{grade}_L{load:02}_S{side}_{seq:04}`
/// → `P012_B_L03_S2_0047`, or `{session}_{seq:04}` → `2026-11-01_0012`.  The
/// extension comes from the file itself.
///
/// Tokens are `{name}` or `{name:NN}` (zero-padded to NN digits, numbers
/// only).  A template must contain `{seq}`, which is unique within a session,
/// so two captures can never get the same name.  Sample tokens (pallet,
/// grade, load, side, slots) are only allowed in the sample workflow.
public struct FileNameTemplate: Equatable, Sendable {
    public enum Token: String, CaseIterable, Sendable {
        case session, seq, date, time, pallet, grade, load, side, slots

        /// Only numbers can be zero-padded.
        var isNumeric: Bool {
            switch self {
            case .load, .side, .seq: true
            case .session, .pallet, .grade, .date, .time, .slots: false
            }
        }

        /// Tokens that need the sample workflow.
        public var isSampleToken: Bool {
            switch self {
            case .pallet, .grade, .load, .side, .slots: true
            case .session, .seq, .date, .time: false
            }
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case unknownToken(String)
        case unclosedBrace
        case invalidWidth(String)
        case missingSequence
        /// A sample token in a simple-mode template.
        case sampleTokenNotAvailable(String)
    }

    /// The values a file name is built from.
    public struct Values: Sendable {
        public var session: CaptureSession
        public var date: Date

        public init(session: CaptureSession, date: Date) {
            self.session = session
            self.date = date
        }
    }

    private enum Part: Equatable {
        case literal(String)
        case token(Token, width: Int?)
    }

    // Literal patterns that are valid by construction (covered by tests).
    public static let standardSample = try! FileNameTemplate(
        "{pallet}_{grade}_L{load:02}_S{side}_{seq:04}", mode: .sampleWorkflow)
    public static let standardSimple = try! FileNameTemplate("{session}_{seq:04}", mode: .simple)

    public let pattern: String
    private let parts: [Part]

    public init(_ pattern: String, mode: CaptureMode) throws(Error) {
        var parts: [Part] = []
        var literal = ""
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{") {
            literal += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { throw .unclosedBrace }
            if !literal.isEmpty {
                parts.append(.literal(literal))
                literal = ""
            }
            let part = try Self.token(String(rest[rest.index(after: open)..<close]))
            if mode == .simple, case .token(let token, _) = part, token.isSampleToken {
                throw .sampleTokenNotAvailable(token.rawValue)
            }
            parts.append(part)
            rest = rest[rest.index(after: close)...]
        }
        literal += rest
        if !literal.isEmpty { parts.append(.literal(literal)) }
        guard parts.contains(where: { if case .token(.seq, _) = $0 { true } else { false } }) else {
            throw .missingSequence
        }
        self.pattern = pattern
        self.parts = parts
    }

    /// The file name without extension, safe for any filesystem.
    public func fileName(for values: Values) -> String {
        Self.sanitized(render(values, missing: { _ in "" }))
    }

    /// The file name for display before every value is filled in: missing
    /// values show as `‹grade›`, so the user sees what's still needed.
    public func preview(for values: Values) -> String {
        Self.sanitized(render(values, missing: { "‹\($0.rawValue)›" }))
    }

    /// The sequence number in `fileName` (without extension) if this
    /// template could have rendered it, e.g. 47 in `P012_B_L03_S2_0047` —
    /// so files without a record still count when numbering goes on.
    public func sequence(in fileName: String) -> Int? {
        let pattern = parts.map { part in
            switch part {
            case .literal(let text): NSRegularExpression.escapedPattern(for: Self.replacingUnsafe(text))
            case .token(.seq, _): "(\\d+)"
            case .token(let token, _): token.isNumeric ? "\\d+" : ".*?"
            }
        }.joined()
        guard let regex = try? Regex(pattern),
            let match = try? regex.wholeMatch(in: fileName),
            let digits = match.output[1].substring
        else { return nil }
        return Int(digits)
    }

    private func render(_ values: Values, missing: (Token) -> String) -> String {
        parts.map { part in
            switch part {
            case .literal(let text): return text
            case .token(let token, let width):
                let value = Self.value(of: token, width: width, in: values)
                return value.isEmpty ? missing(token) : value
            }
        }.joined()
    }

    // MARK: - Private

    private static func token(_ text: String) throws(Error) -> Part {
        let pieces = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let token = Token(rawValue: String(pieces[0])) else { throw .unknownToken(text) }
        guard pieces.count == 2 else { return .token(token, width: nil) }
        guard token.isNumeric, let width = Int(pieces[1]), (1...9).contains(width) else {
            throw .invalidWidth(text)
        }
        return .token(token, width: width)
    }

    private static func value(of token: Token, width: Int?, in values: Values) -> String {
        let sample = values.session.sample
        switch token {
        case .session: return values.session.name
        case .seq: return padded(values.session.nextSequence, to: width)
        case .pallet: return sample?.pallet ?? ""
        case .grade: return sample?.grade ?? ""
        case .load: return sample.map { padded($0.load, to: width) } ?? ""
        case .side: return sample.map { padded($0.side, to: width) } ?? ""
        case .slots: return sample?.slots.map(String.init).joined() ?? ""
        case .date:
            return values.date.formatted(
                .verbatim(
                    "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)", timeZone: .current,
                    calendar: .current))
        case .time:
            return values.date.formatted(
                .verbatim(
                    "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                    timeZone: .current, calendar: .current))
        }
    }

    private static func padded(_ number: Int, to width: Int?) -> String {
        let digits = String(number)
        guard let width, digits.count < width else { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }

    /// Path separators, colons, semicolons, line breaks and control
    /// characters become "-"; leading dots and surrounding whitespace go, so
    /// the name is never hidden or split into folders — nor split in the
    /// log, which joins a capture's file names with ";".
    private static func sanitized(_ name: String) -> String {
        var trimmed = replacingUnsafe(name).trimmingCharacters(in: .whitespaces)
        while trimmed.hasPrefix(".") { trimmed.removeFirst() }
        return trimmed
    }

    private static func replacingUnsafe(_ text: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:;").union(.controlCharacters).union(.newlines)
        return String(text.unicodeScalars.map { unsafe.contains($0) ? "-" : Character($0) })
    }
}
