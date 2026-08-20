import Foundation

/// A resolved version for a release: a distro-style numeric version
/// ("24.04.3", "41", "12.7.0"), a change date (ETag/Last-Modified sources, and
/// date-shaped versions such as Arch's "2026.08.01"), or a Windows feature
/// release ("22H2", "25H2" — PRD F43).
public enum VersionToken: Codable, Hashable, Sendable {
    case semantic([Int], raw: String)
    case date(Date, raw: String)
    /// PRD F43. A Windows feature release, `NNHN`: two-digit calendar year and a
    /// half-of-year ordinal. Deliberately a **case of its own** rather than a
    /// semantic `[22, 2]`, for two reasons:
    ///
    /// * "22H2" and "22.2" are different namespaces. As a semantic token they
    ///   would compare equal, and `Staleness` decides comparability by kind — a
    ///   distinct case is what makes a feature release incomparable with a build
    ///   number (19045.7663), with a distro version, and with a change date, so
    ///   the honest answer stays `.unknown` instead of a fabricated "stale".
    /// * The ordering it needs is exactly (year, half) and nothing else: no
    ///   implicit trailing zeros, no third component. 25H2 > 22H2 > 21H1 falls
    ///   out of comparing the pair.
    case windowsRelease(year: Int, half: Int, raw: String)

    public var raw: String {
        switch self {
        case .semantic(_, let raw), .date(_, let raw), .windowsRelease(_, _, let raw): return raw
        }
    }

    /// Numeric components of a semantic token (empty for date tokens).
    public var numericComponents: [Int] {
        guard case .semantic(let parts, _) = self else { return [] }
        return parts
    }

    // MARK: - Parsing

    /// Date-shaped versions use a 4-digit year and a valid month/day, e.g. "2026.08.01"
    /// or "2026-08-01". Anything else numeric-and-dotted is treated as semantic.
    private static let dateSeparators = CharacterSet(charactersIn: ".-_/")

    public static func parse(_ string: String) -> VersionToken? {
        let raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        // PRD F43: "22H2"/"25H2". Checked before the numeric split, which would
        // reject it anyway — the "H" is not a separator this type recognises.
        if let release = windowsRelease(raw) { return release }

        let fields = raw.components(separatedBy: dateSeparators).filter { !$0.isEmpty }
        guard !fields.isEmpty, fields.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = fields.compactMap { Int($0) }
        guard numbers.count == fields.count else { return nil }

        if let date = dateValue(fields: fields, numbers: numbers) {
            return .date(date, raw: raw)
        }
        return .semantic(numbers, raw: raw)
    }

    /// `NNHN`, case-insensitive on the "H" (PRD F43). Two digits, "H", one digit
    /// — Microsoft's own shape for 21H1, 22H2, 24H2, 25H2, 26H1. Anything longer
    /// or shorter is not a feature release and is left to the numeric path,
    /// which will refuse it: guessing here is how "22H2" would silently become
    /// something comparable to a distro version.
    private static func windowsRelease(_ raw: String) -> VersionToken? {
        let characters = Array(raw)
        guard characters.count == 4,
              characters[0].isNumber, characters[1].isNumber,
              characters[2] == "H" || characters[2] == "h",
              characters[3].isNumber,
              let year = Int(String(characters[0...1])),
              let half = Int(String(characters[3]))
        else { return nil }
        return .windowsRelease(year: year, half: half, raw: raw)
    }

    private static func dateValue(fields: [String], numbers: [Int]) -> Date? {
        guard fields.count == 3, fields[0].count == 4 else { return nil }
        let (year, month, day) = (numbers[0], numbers[1], numbers[2])
        guard year >= 1970, (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey { case kind, parts, date, raw, year, half }
    private enum Kind: String, Codable { case semantic, date, windowsRelease }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .raw)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .semantic:
            self = .semantic(try container.decode([Int].self, forKey: .parts), raw: raw)
        case .date:
            self = .date(try container.decode(Date.self, forKey: .date), raw: raw)
        case .windowsRelease:
            self = .windowsRelease(year: try container.decode(Int.self, forKey: .year),
                                   half: try container.decode(Int.self, forKey: .half),
                                   raw: raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(raw, forKey: .raw)
        switch self {
        case .semantic(let parts, _):
            try container.encode(Kind.semantic, forKey: .kind)
            try container.encode(parts, forKey: .parts)
        case .date(let date, _):
            try container.encode(Kind.date, forKey: .kind)
            try container.encode(date, forKey: .date)
        case .windowsRelease(let year, let half, _):
            try container.encode(Kind.windowsRelease, forKey: .kind)
            try container.encode(year, forKey: .year)
            try container.encode(half, forKey: .half)
        }
    }
}

// MARK: - Comparable

extension VersionToken: Comparable {
    /// Semantic versions compare component-wise with implicit trailing zeros
    /// ("24.04" == "24.04.0"). Dates compare chronologically. Windows feature
    /// releases compare by (year, half), so 25H2 > 22H2 > 21H1. Mixed kinds are
    /// not meaningfully ordered; they are ranked semantic < date < windowsRelease
    /// so ordering stays total and deterministic. `Staleness` refuses to draw a
    /// conclusion from a mixed-kind comparison, which is what keeps that
    /// arbitrary ranking from ever being read as meaning.
    public static func < (lhs: VersionToken, rhs: VersionToken) -> Bool {
        switch (lhs, rhs) {
        case (.semantic(let l, _), .semantic(let r, _)):
            let width = max(l.count, r.count)
            for (x, y) in zip(padded(l, to: width), padded(r, to: width)) where x != y { return x < y }
            return false
        case (.date(let l, _), .date(let r, _)):
            return l < r
        case (.windowsRelease(let ly, let lh, _), .windowsRelease(let ry, let rh, _)):
            return ly == ry ? lh < rh : ly < ry
        default:
            return kindRank(lhs) < kindRank(rhs)
        }
    }

    public static func == (lhs: VersionToken, rhs: VersionToken) -> Bool {
        switch (lhs, rhs) {
        case (.semantic(let l, _), .semantic(let r, _)):
            let width = max(l.count, r.count)
            return padded(l, to: width) == padded(r, to: width)
        case (.date(let l, _), .date(let r, _)):
            return l == r
        case (.windowsRelease(let ly, let lh, _), .windowsRelease(let ry, let rh, _)):
            return ly == ry && lh == rh
        default:
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .semantic(let parts, _):
            hasher.combine(0)
            // Trailing zeros are insignificant ("24.04" == "24.04.0").
            var trimmed = parts
            while trimmed.last == 0 { trimmed.removeLast() }
            hasher.combine(trimmed)
        case .date(let date, _):
            hasher.combine(1)
            hasher.combine(date)
        case .windowsRelease(let year, let half, _):
            hasher.combine(2)
            hasher.combine(year)
            hasher.combine(half)
        }
    }

    private static func kindRank(_ token: VersionToken) -> Int {
        switch token {
        case .semantic: return 0
        case .date: return 1
        case .windowsRelease: return 2
        }
    }

    private static func padded(_ parts: [Int], to count: Int) -> [Int] {
        parts + Array(repeating: 0, count: max(0, count - parts.count))
    }
}
