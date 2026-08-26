import Foundation

// MARK: - Regex

/// Compiled `NSRegularExpression`s, kept.
///
/// Compiling one costs tens of microseconds, which is nothing until it happens
/// in a loop: matching a handful of files against every channel in the catalog
/// is hundreds of compilations, and the drive view did exactly that on every
/// redraw. `NSRegularExpression` is immutable and safe to match on from several
/// threads, so one compiled copy per pattern serves everybody.
final class RegexCache: @unchecked Sendable {
    private struct Key: Hashable {
        let pattern: String
        let caseInsensitive: Bool
    }

    static let shared = RegexCache()
    /// The catalog's patterns are a fixed set; the cap only exists so that a
    /// pathological caller — the custom-source editor recompiling on every
    /// keystroke — cannot grow this without bound.
    private static let capacity = 512

    private let lock = NSLock()
    private var cache: [Key: NSRegularExpression] = [:]
    private var compilations = 0

    /// How many patterns have actually been compiled. The point of the cache is
    /// that this stops growing once the catalog has been seen, and tests assert
    /// exactly that rather than timing anything.
    var compileCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return compilations
    }

    func regex(_ pattern: String, caseInsensitive: Bool) throws -> NSRegularExpression {
        let key = Key(pattern: pattern, caseInsensitive: caseInsensitive)
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached { return cached }

        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        // Failures are not cached: they are rare, and remembering one would mean
        // remembering a pattern the user is still typing.
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            throw ProviderError.invalidRegex(pattern)
        }
        lock.lock()
        if cache.count >= Self.capacity { cache.removeAll(keepingCapacity: true) }
        cache[key] = compiled
        compilations += 1
        lock.unlock()
        return compiled
    }
}

/// Thin wrapper over `NSRegularExpression` (chosen over Swift's `Regex` because
/// the patterns come from JSON/user input at runtime, and because it exists on Linux).
public struct PatternMatcher: Sendable {
    public let pattern: String
    private let regex: NSRegularExpression

    public init(_ pattern: String, caseInsensitive: Bool = false) throws {
        self.regex = try RegexCache.shared.regex(pattern, caseInsensitive: caseInsensitive)
        self.pattern = pattern
    }

    /// All matches in `text`; each element is the list of groups (index 0 = whole match).
    public func matches(in text: String) -> [[String]] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
        }
    }

    public func firstMatch(in text: String) -> [String]? { matches(in: text).first }

    /// Convenience for "does this filename match": whole-string search, not anchored.
    public func matchesAnywhere(_ text: String) -> Bool { firstMatch(in: text) != nil }

    /// Capture group 1 of the first match, or the whole match when the pattern has no group.
    public func capturedVersion(in text: String) -> String? {
        guard let groups = firstMatch(in: text) else { return nil }
        return groups.count > 1 && !groups[1].isEmpty ? groups[1] : groups[0]
    }
}

// MARK: - Candidate selection

/// A parsed candidate release line/link, before the highest version is picked.
public struct VersionCandidate: Sendable {
    public var version: VersionToken
    public var fileName: String
    public var sha256: String?
    public var url: URL?
    public var sizeBytes: Int64?

    public init(version: VersionToken, fileName: String, sha256: String? = nil,
                url: URL? = nil, sizeBytes: Int64? = nil) {
        self.version = version
        self.fileName = fileName
        self.sha256 = sha256
        self.url = url
        self.sizeBytes = sizeBytes
    }
}

public extension Array where Element == VersionCandidate {
    /// Highest version wins; ties keep the first occurrence (source order).
    var highest: VersionCandidate? {
        guard var best = first else { return nil }
        for candidate in dropFirst() where best.version < candidate.version { best = candidate }
        return best
    }
}

// MARK: - Checksum files

public enum ChecksumParsing {
    /// One `(sha256, filename)` pair from a sums file.
    public struct Line: Equatable, Sendable {
        public let hash: String
        public let fileName: String
    }

    private static let hexDigits = Set("0123456789abcdef")

    /// True for a 64-character lowercase-hex string (a SHA-256 digest). Used to
    /// skip the MD5/SHA1/SHA512 sections of mixed files such as GParted's and
    /// Clonezilla's `CHECKSUMS.TXT`.
    public static func isSHA256(_ candidate: String) -> Bool {
        candidate.count == 64 && candidate.lowercased().allSatisfy(hexDigits.contains)
    }

    /// Parses the two formats in the wild:
    ///   * GNU coreutils: `<hash>  <filename>` (the filename may carry a `*`
    ///     binary marker, as Ubuntu's and Mint's files do)
    ///   * BSD tagged:    `SHA256 (<filename>) = <hash>`
    /// Lines with a non-SHA-256 digest, comments and section headers are ignored.
    public static func lines(in text: String) -> [Line] {
        var result: [Line] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if let bsd = parseBSD(line) {
                result.append(bsd)
            } else if let gnu = parseGNU(line) {
                result.append(gnu)
            }
        }
        return result
    }

    private static func parseGNU(_ line: String) -> Line? {
        let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard fields.count == 2 else { return nil }
        let hash = String(fields[0])
        guard isSHA256(hash) else { return nil }
        var name = fields[1].trimmingCharacters(in: .whitespaces)
        // "*" marks binary mode in coreutils output; " " marks text mode.
        if name.hasPrefix("*") { name.removeFirst() }
        guard !name.isEmpty else { return nil }
        return Line(hash: hash.lowercased(), fileName: name)
    }

    private static func parseBSD(_ line: String) -> Line? {
        guard line.uppercased().hasPrefix("SHA256 (") || line.uppercased().hasPrefix("SHA2-256 ("),
              let open = line.firstIndex(of: "("),
              let close = line.range(of: ") = ", options: .backwards) else { return nil }
        let name = String(line[line.index(after: open)..<close.lowerBound])
        let hash = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard isSHA256(hash), !name.isEmpty else { return nil }
        return Line(hash: hash.lowercased(), fileName: name)
    }

    /// A single-hash file (`foo.iso.sha256`) is often just the digest, sometimes
    /// `<hash>  foo.iso`. Returns the digest either way.
    public static func singleHash(in text: String) -> String? {
        if let line = lines(in: text).first { return line.hash }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).first.map(String.init)
        guard let token, isSHA256(token) else { return nil }
        return token.lowercased()
    }
}

// MARK: - HTML anchors

public enum HTMLParsing {
    private static let hrefPattern = #"href\s*=\s*["']([^"']+)["']"#

    /// Extracts `href` values. Deliberately a regex, not an HTML parser: the
    /// pages we scrape are Apache/nginx directory indexes and simple download
    /// pages, and a parser dependency is banned (DESIGN §1/§4.1).
    public static func hrefs(in html: String) -> [String] {
        guard let matcher = try? PatternMatcher(hrefPattern, caseInsensitive: true) else { return [] }
        return matcher.matches(in: html).compactMap { $0.count > 1 ? $0[1] : nil }
    }
}

// MARK: - JSON paths

/// Mini path language for `.jsonFeed` field lookups:
///   * `a.b`            — object keys
///   * `a.0`            — array index
///   * `a.[type=iso].b` — first array element whose `type` equals `iso`
/// Keys containing dots are not supported (no source needs them).
public enum JSONPath {
    public static func value(_ root: Any?, at path: String) -> Any? {
        var current = root
        for segment in split(path) where current != nil {
            current = step(current, segment: segment)
        }
        return current
    }

    public static func string(_ root: Any?, at path: String) -> String? {
        switch value(root, at: path) {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    public static func int64(_ root: Any?, at path: String) -> Int64? {
        switch value(root, at: path) {
        case let number as NSNumber: return number.int64Value
        case let text as String: return Int64(text)
        default: return nil
        }
    }

    static func split(_ path: String) -> [String] {
        path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
    }

    private static func step(_ node: Any?, segment: String) -> Any? {
        if segment.hasPrefix("["), segment.hasSuffix("]") {
            let inner = String(segment.dropFirst().dropLast())
            let parts = inner.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let array = node as? [Any] else { return nil }
            return array.first { element in
                string(element, at: parts[0]) == parts[1]
            }
        }
        if let index = Int(segment), let array = node as? [Any] {
            return array.indices.contains(index) ? array[index] : nil
        }
        return (node as? [String: Any])?[segment]
    }
}
