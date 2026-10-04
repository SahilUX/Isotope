import Foundation
import IsotopeCore

/// One ISO found sitting in the user's Downloads folder.
struct FoundISO: Identifiable, Hashable, Sendable {
    var url: URL
    var fileName: String
    var sizeBytes: Int64
    var modifiedAt: Date

    var id: URL { url }
}

/// PRD §5.4: Microsoft's ISO links are session-generated, so Isotope sends the
/// user to the browser and then watches `~/Downloads` for the file to land.
///
/// Polling rather than an FSEvents stream: the watch is only live while the
/// Windows sheet is open, and a five-second poll over one directory is cheaper
/// than the machinery of a stream (and works identically under the sandbox's
/// `files.downloads.read-only` entitlement).
@Observable
@MainActor
final class DownloadsWatcher {
    /// ISOs whose name matches what this entry's media is called.
    private(set) var candidates: [FoundISO] = []
    /// Every *other* `.iso` in the folder, newest first, minus the ones that are
    /// recognisably some other catalog image. A recognition pattern that
    /// misses — a renamed file, a naming change at the vendor — must not leave
    /// the user with an empty list and a file dialog; the file is right there,
    /// so offer it. A `Win10_…` file in the Windows 11 sheet is not that file.
    private(set) var otherISOs: [FoundISO] = []
    /// False when the folder could not be read at all, which on macOS usually
    /// means the app has not been granted access to it. Worth saying out loud:
    /// it looks identical to "your download has not arrived" otherwise.
    private(set) var folderIsReadable = true
    private(set) var isWatching = false
    private var task: Task<Void, Never>?

    /// How many unmatched ISOs to offer. Enough to cover "I downloaded it
    /// yesterday", short enough not to become a file browser.
    static let maxOtherISOs = 8

    /// Regex matched against the filename; the catalog's own recognition
    /// pattern for the entry, when it has one.
    var pattern: String = #"(?i)^win.*\.iso$"#
    /// What identifies the other catalog entries' media: their recognition
    /// patterns and names. A file one of them claims is that entry's media, so
    /// it is not offered here as a fallback.
    var excludedPatterns: [String] = []
    var interval: TimeInterval = 5
    var folder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")

    func start() {
        guard task == nil else { return }
        isWatching = true
        scan()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.interval else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.scan()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isWatching = false
    }

    /// Newest first — the file the user just fetched is the one they mean.
    func scan() {
        let result = Self.scan(folder: folder, pattern: pattern, excluding: excludedPatterns)
        folderIsReadable = result.isReadable
        candidates = result.matching
        otherISOs = Array(result.other.prefix(Self.maxOtherISOs))
    }

    /// Every ISO in the folder, split by whether it matches `pattern`. ISOs
    /// that match none of it but one of `excluding` are dropped entirely.
    /// `isReadable` distinguishes "no ISOs here" from "could not look".
    static func scan(folder: URL, pattern: String, excluding: [String] = [])
        -> (matching: [FoundISO], other: [FoundISO], isReadable: Bool) {
        let matcher = try? PatternMatcher(pattern, caseInsensitive: true)
        let excluders = excluding.compactMap { try? PatternMatcher($0, caseInsensitive: true) }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return ([], [], false) }

        let isos = contents.compactMap { url -> FoundISO? in
            let name = url.lastPathComponent
            guard DownloadArtifact.isISO(name) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile != false else { return nil }
            return FoundISO(url: url, fileName: name,
                            sizeBytes: Int64(values?.fileSize ?? 0),
                            modifiedAt: values?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }

        let matches = { (iso: FoundISO) in matcher?.matchesAnywhere(iso.fileName) ?? true }
        let belongsElsewhere = { (iso: FoundISO) in
            excluders.contains { $0.matchesAnywhere(iso.fileName) }
        }
        return (isos.filter(matches), isos.filter { !matches($0) && !belongsElsewhere($0) }, true)
    }

    /// A pattern finding an entry's name in a filename regardless of the
    /// separators between its words: "Windows 11" matches `Windows11_Client`,
    /// `windows-11` and `Windows 11`, but not `Windows 10` or `Windows 110`.
    /// Nil for a name with nothing alphanumeric in it.
    static func namePattern(for name: String) -> String? {
        let words = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard let last = words.last?.last else { return nil }
        let body = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "[^a-z0-9]*")
        let end = last.isNumber ? "(?![0-9])" : "(?![a-z])"
        return "(?i)(?<![a-z0-9])" + body + end
    }

    static func matches(in folder: URL, pattern: String) -> [FoundISO] {
        scan(folder: folder, pattern: pattern).matching
    }
}
