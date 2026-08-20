import Foundation

/// What a stick's volume label says it contains (PRD F40).
///
/// `channelID` is nil when the entry's own pattern matched and no channel
/// narrowed it down; `version` is nil when the label identifies the image but
/// carries no version (Kali's "Kali Linux amd64 1", Proxmox's "PVE") or when the
/// captured text is not a parseable version.
public struct VolumeLabelMatch: Hashable, Sendable {
    public var entryID: String
    public var channelID: String?
    public var version: VersionToken?
    /// The label the match came from, so the UI can show what it read.
    public var label: String

    public init(entryID: String, channelID: String? = nil, version: VersionToken? = nil,
                label: String) {
        self.entryID = entryID
        self.channelID = channelID
        self.version = version
        self.label = label
    }
}

/// Pure label → catalog matching (PRD F40). Foundation only, no device access:
/// the labels come from DiskArbitration in the app layer and are handed in as
/// plain strings, so this is table-testable and portable.
///
/// Deliberately conservative. A stick is only claimed when a pattern matches the
/// *whole* label from its start; when two different entries claim the same set
/// of labels the result is reported as ambiguous rather than guessed at, because
/// preselecting the wrong image in a flash confirmation is a data-loss bug.
public enum VolumeLabelMatcher {
    /// Every entry whose pattern matches `label`. Channel patterns are tried
    /// first, so a Debian netinst stick resolves to the netinst channel rather
    /// than to the entry alone.
    public static func matches(label: String, in entries: [CatalogEntry]) -> [VolumeLabelMatch] {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return entries.compactMap { match(label: trimmed, entry: $0) }
    }

    /// One entry against one label. Nil when the entry has no pattern, or none
    /// of its patterns match.
    public static func match(label: String, entry: CatalogEntry) -> VolumeLabelMatch? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for channel in entry.channels {
            guard let pattern = channel.volumeLabelPattern,
                  let captured = capture(pattern: pattern, in: trimmed) else { continue }
            return VolumeLabelMatch(entryID: entry.id, channelID: channel.id,
                                    version: captured.flatMap(VersionToken.parse), label: trimmed)
        }
        guard let pattern = entry.volumeLabelPattern,
              let captured = capture(pattern: pattern, in: trimmed) else { return nil }
        return VolumeLabelMatch(entryID: entry.id, channelID: nil,
                                version: captured.flatMap(VersionToken.parse), label: trimmed)
    }

    /// The single entry a set of labels points at, or nil when nothing matches
    /// or two different entries do (a Ventoy stick can carry several volumes;
    /// only an unambiguous answer is worth preselecting).
    public static func bestMatch(labels: [String], in entries: [CatalogEntry]) -> VolumeLabelMatch? {
        let all = labels.flatMap { matches(label: $0, in: entries) }
        guard let first = all.first else { return nil }
        guard all.allSatisfy({ $0.entryID == first.entryID }) else { return nil }
        // Prefer the richest match for that entry: a channel and a version say
        // more than a bare entry hit, and both come from the same stick.
        return all.max { rank($0) < rank($1) } ?? first
    }

    /// Whether a label still describes the entry (and channel) a registered
    /// flashed drive is recorded as holding — the attach-time check in F40.
    /// Returns the match so the caller can compare versions, or nil when the
    /// stick no longer looks like that image at all.
    public static func match(labels: [String], entry: CatalogEntry,
                             channelID: String?) -> VolumeLabelMatch? {
        for label in labels {
            guard let found = match(label: label, entry: entry) else { continue }
            // A channel-specific pattern that names a *different* channel is
            // still the same image family; the recorded channel wins for
            // display, but the version we read is the one on the stick.
            guard found.channelID == nil || channelID == nil || found.channelID == channelID
            else { continue }
            return found
        }
        return nil
    }

    // MARK: - Internals

    /// Nil when the pattern does not match; `.some(nil)` when it matches with no
    /// participating capture group; `.some(text)` when group 1 captured.
    private static func capture(pattern: String, in label: String) -> String?? {
        guard let matcher = try? PatternMatcher(pattern),
              let groups = matcher.firstMatch(in: label) else { return nil }
        guard groups.count > 1, !groups[1].isEmpty else { return .some(nil) }
        return .some(groups[1])
    }

    private static func rank(_ match: VolumeLabelMatch) -> Int {
        (match.channelID == nil ? 0 : 2) + (match.version == nil ? 0 : 1)
    }
}
