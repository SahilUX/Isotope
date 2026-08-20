import Foundation

/// PRD F44: one "read this small marker file and parse a version out of it"
/// instruction for a flashed drive's mounted volume.
///
/// A dd-flashed stick is the ISO, so the ISO's own marker files are sitting
/// there in plain sight — `.disk/info` on every Debian-derived image. Reading
/// one is read-only, needs no administrator rights and no raw device access,
/// and answers the question the volume label cannot: Proxmox VE's label is
/// literally "PVE" and carries no version at all.
///
/// Every field is data, not code, so a format drift is fixed by editing
/// `catalog.json`.
public struct ContentProbe: Codable, Hashable, Sendable {
    /// Volume-relative path, e.g. ".disk/info". A leading "/" is tolerated and
    /// stripped by the caller; `..` components are refused (see `safeRelativePath`).
    public var path: String
    /// Regex applied to the file's text. Capture groups feed `versionTemplate`.
    public var pattern: String
    /// How the capture groups become a version string. `$1`, `$2`, … are
    /// substituted; nil means "$1", which is what a single-group pattern wants.
    ///
    /// It exists because one real format needs it: Proxmox VE's `.disk/info`
    /// splits the version across two lines (`RELEASE='9.2'` and
    /// `ISORELEASE='1'`) and the catalog's own version format is "9.2-1". A
    /// single capture group cannot rejoin them, and inventing a version out of
    /// half the evidence would be worse than reporting nothing.
    public var versionTemplate: String?

    public init(path: String, pattern: String, versionTemplate: String? = nil) {
        self.path = path
        self.pattern = pattern
        self.versionTemplate = versionTemplate
    }

    /// `path` reduced to something that can only ever resolve *inside* the
    /// volume: no absolute root, no parent traversal. Nil when the path is
    /// empty or tries to escape — a catalog typo must not turn into a read
    /// somewhere else on the machine.
    public var safeRelativePath: String? {
        let components = path.split(separator: "/").map(String.init)
            .filter { !$0.isEmpty && $0 != "." }
        guard !components.isEmpty, !components.contains("..") else { return nil }
        return components.joined(separator: "/")
    }
}

/// Runs a `ContentProbe` list against already-read file contents (PRD F44).
///
/// Foundation only and completely I/O-free: the app layer does the reading and
/// hands the text in, which is what makes the whole decision table-testable
/// without a USB stick — and what keeps the rule "the probe never writes"
/// structurally true rather than merely intended.
public enum ContentProbeRunner {
    /// The first probe, in catalog order, that reads, matches and parses.
    /// Ordered on purpose: the first probe is the most specific evidence, and a
    /// later one is a fallback, never an override.
    ///
    /// `read` returns nil for a file that is absent or unreadable — both are
    /// silence, and silence just moves on to the next probe.
    public static func version(probes: [ContentProbe],
                               read: (String) -> String?) -> VersionToken? {
        for probe in probes {
            guard let path = probe.safeRelativePath,
                  let text = read(path),
                  let version = parse(probe: probe, text: text) else { continue }
            return version
        }
        return nil
    }

    /// One probe against one file's text. Nil when the pattern is broken, does
    /// not match, or produces something that is not a version — a malformed
    /// marker file yields no answer rather than a wrong one.
    public static func parse(probe: ContentProbe, text: String) -> VersionToken? {
        guard let matcher = try? PatternMatcher(probe.pattern),
              let groups = matcher.firstMatch(in: text) else { return nil }
        let rendered = render(template: probe.versionTemplate ?? "$1", groups: groups)
        guard !rendered.isEmpty else { return nil }
        return VersionToken.parse(rendered)
    }

    /// `$1`/`$2`… substitution. A reference to a group the pattern does not have
    /// (or that did not participate) makes the whole render fail, so a partial
    /// version is never assembled.
    private static func render(template: String, groups: [String]) -> String {
        var result = ""
        var characters = Array(template)[...]
        while let character = characters.first {
            characters = characters.dropFirst()
            guard character == "$", let digit = characters.first, digit.isNumber else {
                result.append(character)
                continue
            }
            var number = ""
            while let next = characters.first, next.isNumber {
                number.append(next)
                characters = characters.dropFirst()
            }
            guard let index = Int(number), index < groups.count, !groups[index].isEmpty
            else { return "" }
            result.append(groups[index])
        }
        return result
    }
}
