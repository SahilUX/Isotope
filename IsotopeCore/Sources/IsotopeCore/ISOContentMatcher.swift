import Foundation

/// A file on a Ventoy drive that no assignment claims, recognised as a catalog
/// entry by its filename (PRD F41).
///
/// `channelID` is nil when several channels of the *same* entry match the name —
/// Ubuntu's LTS and Latest channels share one filename pattern, so the file says
/// which image it is but not which channel is meant to track it. `version` is nil
/// when the pattern matched but its capture group holds nothing parseable.
public struct DetectedISO: Hashable, Sendable, Identifiable {
    public var fileName: String
    public var entryID: String
    public var channelID: String?
    public var version: VersionToken?

    /// The filename is the identity: each unclaimed file is offered at most once.
    public var id: String { fileName }

    public init(fileName: String, entryID: String, channelID: String? = nil,
                version: VersionToken? = nil) {
        self.fileName = fileName
        self.entryID = entryID
        self.channelID = channelID
        self.version = version
    }
}

/// Pure filename → catalog matching for the files a drive scan could not place
/// (PRD F41). Foundation only, no file access: the names come from
/// `ReconcileResult.unknownFiles` and are handed in as plain strings, so this is
/// table-testable and portable.
///
/// It reuses the very patterns reconcile pass 2 matches with
/// (`ProviderConfig.fileNamePattern`), across *all* catalog entries rather than
/// only the assigned ones — that is the whole of the difference.
///
/// Deliberately conservative, like `VolumeLabelMatcher`: when two different
/// entries claim one filename the file is not offered at all, because a wrong
/// offer invites the user to create an assignment that then tracks the wrong
/// image. Exclusive claiming still holds — the caller only ever passes files no
/// assignment recorded or matched, so an ISO another assignment owns is never
/// re-offered.
public enum ISOContentMatcher {
    /// Every unclaimed file that maps to exactly one catalog entry, in the order
    /// the files came in.
    public static func detect(unclaimedFiles: [String], in entries: [CatalogEntry]) -> [DetectedISO] {
        DriveScan.isoFileNames(in: unclaimedFiles).compactMap { match(fileName: $0, in: entries) }
    }

    /// One file against the whole catalog. Nil when nothing matches, or when
    /// two different entries do.
    public static func match(fileName: String, in entries: [CatalogEntry]) -> DetectedISO? {
        guard DriveScan.isISOFileName(fileName) else { return nil }
        var entryID: String?
        var hits: [(channelID: String, version: VersionToken?)] = []
        for entry in entries {
            let matched = channelMatches(fileName: fileName, entry: entry)
            guard !matched.isEmpty else { continue }
            // A second, different entry claiming the same name: ambiguous.
            guard entryID == nil else { return nil }
            entryID = entry.id
            hits = matched
        }
        guard let entryID, let first = hits.first else { return nil }
        // Several channels of one entry (Ubuntu LTS/Latest share a pattern):
        // the image is known, the channel is the user's call.
        let channelID = hits.count == 1 ? first.channelID : nil
        return DetectedISO(fileName: fileName, entryID: entryID, channelID: channelID,
                           version: first.version)
    }

    /// The IDs of `entry`'s channels whose filename pattern matches `fileName`,
    /// so the UI can offer the channel choice for an entry-level match.
    public static func matchingChannelIDs(fileName: String, entry: CatalogEntry) -> [String] {
        channelMatches(fileName: fileName, entry: entry).map(\.channelID)
    }

    // MARK: - Internals

    private static func channelMatches(fileName: String,
                                       entry: CatalogEntry) -> [(channelID: String, version: VersionToken?)] {
        entry.channels.compactMap { channel in
            guard let pattern = channel.provider.fileNamePattern, !pattern.isEmpty,
                  // A broken pattern degrades to "no match", never to a crash.
                  let matcher = try? PatternMatcher(pattern, caseInsensitive: true),
                  matcher.matchesAnywhere(fileName) else { return nil }
            let version = matcher.capturedVersion(in: fileName).flatMap(VersionToken.parse)
            return (channel.id, version)
        }
    }
}
