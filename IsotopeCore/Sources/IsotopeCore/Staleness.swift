import Foundation

/// Where one assignment stands against its latest known release (PRD F2/F16).
public enum Staleness: String, Sendable, Equatable, CaseIterable {
    /// Installed version equals or exceeds the latest known release.
    case upToDate
    /// PRD F43 addendum: the installed image is the current *release* but an
    /// older *build* of it — a 25H2 ISO of build 26200.6584 while Microsoft's
    /// release health reports 26200.9168 for 25H2.
    ///
    /// Deliberately not `.stale`. Microsoft services Windows monthly but
    /// refreshes the downloadable media rarely, so "a newer build exists" does
    /// not mean "a newer ISO can be downloaded"; treating it as an update would
    /// prompt for a re-download that returns the same file. It is surfaced,
    /// counted as no update, and left to the user to act on.
    case buildBehind
    /// A newer release exists.
    case stale
    /// Nothing is on the drive for this assignment yet.
    case notInstalled
    /// Not comparable: no resolved release, an unrecognised installed filename,
    /// or a semantic-vs-change-date mismatch between the two sides.
    case unknown
    /// PRD F33: the assignment is pinned (`keepAsIs`), so no comparison is made
    /// at all. Distinct from `upToDate` so the UI can badge it, and never
    /// counted towards "N updates available".
    case pinned

    /// Drives count these towards "N updates available". `buildBehind` is
    /// pointedly not one of them: nothing downloadable is known to be newer.
    public var needsUpdate: Bool { self == .stale || self == .notInstalled }

    /// True where the version comparison itself came out level — the row is not
    /// waiting on anything, whatever extra detail is being shown.
    public var isCurrent: Bool { self == .upToDate || self == .buildBehind }
}

public extension Staleness {
    /// PRD F33/F36: a pinned assignment short-circuits the comparison entirely —
    /// there is nothing to be stale against when the file is never replaced.
    /// Switching back to `trackLatest` re-evaluates normally, because nothing
    /// about the pin is recorded anywhere else.
    static func evaluate(assignment: Assignment, latest: Release?) -> Staleness {
        guard !assignment.isPinned else { return .pinned }
        return evaluate(installed: assignment.installed, latest: latest)
    }

    static func evaluate(installed: InstalledISO?, latest: Release?) -> Staleness {
        let base = evaluate(installedVersion: installed?.version,
                            hasInstalledFile: installed != nil,
                            latest: latest?.version)
        // PRD F48: Microsoft reissues the media for a release without changing
        // the release. Unlike a servicing build, a new issue *is* downloadable
        // today, so it is a plain update — the row says 25H2 → 25H2 v2 and the
        // usual "get this" flow applies.
        let installedRevision = installed.flatMap { WindowsMediaName.revision(fromFileName: $0.fileName) }
        if base == .upToDate, let latestRevision = latest?.mediaRevision,
           let installedRevision, installedRevision < latestRevision {
            return .stale
        }
        // PRD F70: and once the revisions match, the drive holds the media
        // Microsoft is serving — which is the most anyone can have. The build
        // inside it will *always* trail the current serviced build, because
        // servicing ships through Windows Update and not in the ISO, so
        // reporting that gap as a state of the row means reporting it forever,
        // beside a button that re-downloads the identical file.
        //
        // The build is only worth raising where the revision cannot answer:
        // media that is not named the way Microsoft names it, so there is no
        // revision to compare and a newer build is the only hint that newer
        // media might exist.
        if let installedRevision, let latestRevision = latest?.mediaRevision,
           installedRevision >= latestRevision {
            return base
        }
        // PRD F43 addendum: only once the releases are level does the build
        // become the finer question. Both sides must have one, read from
        // like-for-like sources — the image's own metadata against the
        // publisher's build for that release — or there is nothing to say.
        guard base == .upToDate,
              let installedBuild = installed?.buildToken,
              let latestBuild = latest?.build.flatMap(VersionToken.parse),
              case .semantic = installedBuild, case .semantic = latestBuild,
              installedBuild < latestBuild
        else { return base }
        return .buildBehind
    }

    /// Version comparison only. Mixed kinds (`.semantic` vs `.date`) are ordered
    /// by `VersionToken`'s total order for determinism, but that ordering carries
    /// no meaning — a source that switched mechanism reports `.unknown` rather
    /// than a bogus "update available".
    static func evaluate(installedVersion: VersionToken?,
                         hasInstalledFile: Bool,
                         latest: VersionToken?) -> Staleness {
        guard let latest else { return .unknown }
        guard hasInstalledFile else { return .notInstalled }
        guard let installedVersion else { return .unknown }
        guard sameKind(installedVersion, latest) else { return .unknown }
        return installedVersion < latest ? .stale : .upToDate
    }

    private static func sameKind(_ lhs: VersionToken, _ rhs: VersionToken) -> Bool {
        switch (lhs, rhs) {
        case (.semantic, .semantic), (.date, .date), (.windowsRelease, .windowsRelease): return true
        // PRD F43: a feature release ("25H2") and a build number ("26200.9168")
        // are different namespaces. Refusing the comparison is the whole point of
        // giving them separate kinds.
        default: return false
        }
    }
}

public extension ProviderConfig {
    /// The regex that recognises this channel's ISO filenames, when the
    /// mechanism has one. Version is capture group 1 where the pattern has one,
    /// so drive scans reuse the same patterns the providers parse releases with
    /// (PRD F7). `windowsManual`, `staticURL` and `jsonFeed` carry
    /// *recognition-only* patterns: they name the image so a drive scan can place
    /// it (PRD F41), but capture a version only where the filename really holds
    /// the one the provider resolves. Where it does not, the pattern has no
    /// capture group, the match carries no version, and staleness stays
    /// `.unknown` — never a fabricated "update available".
    var fileNamePattern: String? {
        switch self {
        case .checksumFile(_, let filePattern, _, _): return filePattern
        case .pageScrape(_, let linkPattern, _, _): return linkPattern
        case .gitHubReleases(_, let assetPattern): return assetPattern
        case .windowsManual(_, _, _, let fileNamePattern, _, _, _): return fileNamePattern
        case .staticURL(_, _, let fileNamePattern): return fileNamePattern
        case .jsonFeed(_, _, let fileNamePattern): return fileNamePattern
        }
    }
}
