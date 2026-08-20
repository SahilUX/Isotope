import Foundation

// MARK: - File listing helpers

/// Filename-level helpers for a drive's ISO folder. Pure string work so the
/// scan can be unit-tested from a fake listing (DESIGN §7) and reused on Linux.
public enum DriveScan {
    /// True for a visible `.iso` file. Hidden entries (`.` prefix — AppleDouble
    /// `._foo.iso`, in-progress `.foo.iso.part` from a failed copy) never count.
    public static func isISOFileName(_ name: String) -> Bool {
        guard !name.hasPrefix("."), name.count > 4 else { return false }
        return name.lowercased().hasSuffix(".iso")
    }

    /// The visible `.iso` files of a listing, in stable case-insensitive order.
    public static func isoFileNames(in names: [String]) -> [String] {
        names.filter(isISOFileName)
            .sorted { $0.compare($1, options: .caseInsensitive) == .orderedAscending }
    }
}

// MARK: - Reconcile inputs / outputs

/// One assignment's view of the world, flattened so reconciliation needs no
/// catalog lookups: the filename regex from its provider (version in capture
/// group 1), the latest known release's filename/version, and what was recorded
/// as installed last time.
public struct ReconcileInput: Sendable, Equatable {
    public var assignmentID: UUID
    /// Regex over filenames, with the version in capture group 1 where the
    /// source has one (`windowsManual`'s recognition pattern has none, so its
    /// matches carry no version); nil when the provider has no filename pattern
    /// at all (`staticURL`, `jsonFeed`).
    public var fileNamePattern: String?
    /// Exact filename of the latest resolved release. Empty is treated as
    /// "unknown" — Windows 11's cached release carries no filename.
    public var releaseFileName: String?
    public var releaseVersion: VersionToken?
    public var installed: InstalledISO?
    /// PRD F33: a pinned assignment is about the file it holds. Once that file
    /// is on the drive it is never re-pointed at a newer one, so pinned inputs
    /// sit out passes 1 and 2 and keep their recorded file in pass 3. A pin with
    /// nothing installed yet still matches normally — there is nothing to keep.
    public var isPinned: Bool

    public init(assignmentID: UUID,
                fileNamePattern: String? = nil,
                releaseFileName: String? = nil,
                releaseVersion: VersionToken? = nil,
                installed: InstalledISO? = nil,
                isPinned: Bool = false) {
        self.assignmentID = assignmentID
        self.fileNamePattern = fileNamePattern
        self.releaseFileName = releaseFileName
        self.releaseVersion = releaseVersion
        self.installed = installed
        self.isPinned = isPinned
    }

    /// Nil unless the release actually names a file (PRD §5.4 Windows caveat).
    var usableReleaseFileName: String? {
        guard let releaseFileName, !releaseFileName.isEmpty else { return nil }
        return releaseFileName
    }
}

public struct ReconcileOutcome: Sendable, Equatable, Identifiable {
    public enum Change: String, Sendable, Equatable {
        /// The recorded file is still on the drive.
        case unchanged
        /// A matching file was found where a different one (or none) was recorded.
        case discovered
        /// The recorded file is gone and nothing else matched (PRD F7 "missing").
        case missing
        /// Nothing was recorded and nothing matched — still not installed.
        case absent
    }

    public var assignmentID: UUID
    /// The reconciled value for `Assignment.installed` (nil = nothing on the drive).
    public var installed: InstalledISO?
    public var change: Change
    public var previousFileName: String?

    public var id: UUID { assignmentID }

    public init(assignmentID: UUID, installed: InstalledISO?, change: Change,
                previousFileName: String? = nil) {
        self.assignmentID = assignmentID
        self.installed = installed
        self.change = change
        self.previousFileName = previousFileName
    }
}

public struct ReconcileResult: Sendable, Equatable {
    public var outcomes: [ReconcileOutcome]
    /// Visible `.iso` files no assignment claimed — shown informationally, never
    /// touched (PRD F7/F22).
    public var unknownFiles: [String]
    public var scannedAt: Date

    public init(outcomes: [ReconcileOutcome], unknownFiles: [String], scannedAt: Date) {
        self.outcomes = outcomes
        self.unknownFiles = unknownFiles
        self.scannedAt = scannedAt
    }

    /// Outcomes worth persisting/logging: everything that actually moved.
    public var changes: [ReconcileOutcome] {
        outcomes.filter { $0.change == .discovered || $0.change == .missing }
    }

    public func outcome(for assignmentID: UUID) -> ReconcileOutcome? {
        outcomes.first { $0.assignmentID == assignmentID }
    }
}

// MARK: - Reconciler

/// PRD F7: reconcile a drive's ISO folder listing against its assignments.
///
/// Deterministic, allocation-light and side-effect free — the whole of the
/// "which file belongs to which assignment" decision lives here so it can be
/// tested from fake listings (DESIGN §7).
///
/// Files are claimed exclusively, in three passes:
///  1. exact match on the latest release's filename (unambiguous),
///  2. filename-regex match, highest parsed version wins,
///  3. the previously recorded filename, so a hand-placed ISO whose pattern
///     stopped matching is not reported as missing.
/// Assignments are processed in the given order; earlier ones win a contested
/// file (Ubuntu LTS and Latest share a filename shape).
///
/// A file another assignment *records* as its own is off-limits in passes 1 and
/// 2 (PRD F34): with two assignments of one entry+channel — one tracking, one
/// pinned — the tracker's regex matches the pinned copy too, and the highest
/// version may well be the pinned one. Recorded ownership therefore wins, and
/// each file is still claimed exactly once. A newer file *nobody* records is
/// unaffected, so a hand-placed upgrade is still discovered.
///
/// A pinned assignment (PRD F33) whose recorded file is still on the drive takes
/// part in pass 3 alone: a pin is about that one file, and must not migrate to a
/// newer copy just because nothing else claimed it.
public enum DriveReconciler {
    public static func reconcile(fileNames: [String],
                                 assignments: [ReconcileInput],
                                 now: Date = Date()) -> ReconcileResult {
        let isos = DriveScan.isoFileNames(in: fileNames)
        let matchers = assignments.map { input -> PatternMatcher? in
            guard let pattern = input.fileNamePattern, !pattern.isEmpty else { return nil }
            // A broken regex must degrade to "no pattern", never abort the scan.
            return try? PatternMatcher(pattern, caseInsensitive: true)
        }

        var claimed = Set<String>()
        var chosen = [UUID: String]()
        // Files some assignment already records as installed — reserved for it
        // until pass 3 (see the doc comment).
        var recorded = [String: UUID]()
        for input in assignments {
            guard let name = input.installed?.fileName, isos.contains(name) else { continue }
            if recorded[name] == nil { recorded[name] = input.assignmentID }
        }
        func isReserved(_ name: String, for assignmentID: UUID) -> Bool {
            guard let owner = recorded[name] else { return false }
            return owner != assignmentID
        }
        /// PRD F33: a pin whose file is on the drive keeps it, and takes part in
        /// pass 3 only.
        func keepsItsFile(_ input: ReconcileInput) -> Bool {
            guard input.isPinned, let name = input.installed?.fileName else { return false }
            return isos.contains(name)
        }

        // Pass 1 — exact release filename.
        for input in assignments {
            guard !keepsItsFile(input), let name = input.usableReleaseFileName,
                  isos.contains(name), !claimed.contains(name),
                  !isReserved(name, for: input.assignmentID) else { continue }
            chosen[input.assignmentID] = name
            claimed.insert(name)
        }

        // Pass 2 — filename regex, highest version.
        for (input, matcher) in zip(assignments, matchers) {
            guard chosen[input.assignmentID] == nil, !keepsItsFile(input), let matcher else { continue }
            let candidates = isos.filter {
                !claimed.contains($0) && !isReserved($0, for: input.assignmentID)
                    && matcher.matchesAnywhere($0)
            }
            guard let best = highestVersioned(candidates, matcher: matcher) else { continue }
            chosen[input.assignmentID] = best
            claimed.insert(best)
        }

        // Pass 3 — the previously recorded file.
        for input in assignments {
            guard chosen[input.assignmentID] == nil,
                  let name = input.installed?.fileName,
                  isos.contains(name), !claimed.contains(name) else { continue }
            chosen[input.assignmentID] = name
            claimed.insert(name)
        }

        let outcomes = zip(assignments, matchers).map { input, matcher in
            makeOutcome(input: input, matcher: matcher, chosen: chosen[input.assignmentID], now: now)
        }
        return ReconcileResult(outcomes: outcomes,
                               unknownFiles: isos.filter { !claimed.contains($0) },
                               scannedAt: now)
    }

    /// Highest parsed version wins; files whose version cannot be parsed are a
    /// last resort (first in listing order) so an odd name still gets recognised.
    private static func highestVersioned(_ candidates: [String], matcher: PatternMatcher) -> String? {
        var best: (name: String, version: VersionToken)?
        for name in candidates {
            guard let version = version(of: name, matcher: matcher) else { continue }
            if let current = best, !(current.version < version) { continue }
            best = (name, version)
        }
        return best?.name ?? candidates.first
    }

    private static func version(of fileName: String, matcher: PatternMatcher?) -> VersionToken? {
        guard let captured = matcher?.capturedVersion(in: fileName) else { return nil }
        return VersionToken.parse(captured)
    }

    private static func makeOutcome(input: ReconcileInput,
                                    matcher: PatternMatcher?,
                                    chosen: String?,
                                    now: Date) -> ReconcileOutcome {
        guard let chosen else {
            let previous = input.installed?.fileName
            return ReconcileOutcome(assignmentID: input.assignmentID,
                                    installed: nil,
                                    change: previous == nil ? .absent : .missing,
                                    previousFileName: previous)
        }
        if let existing = input.installed, existing.fileName == chosen {
            // Same file as recorded: keep provenance (`placedByApp`) and timestamp.
            //
            // One exception, and it is a re-parse rather than a change: a record
            // written when the pattern captured no version keeps `version: nil`
            // for ever otherwise, because nothing about the file moves. PRD F43
            // taught the Windows patterns to capture `NNHN`, so an assignment
            // adopted before it must be able to learn its own version from the
            // filename it already holds — without that, the file is right, the
            // release is right, and staleness stays "Unknown".
            var updated = existing
            if existing.version == nil, let parsed = version(of: chosen, matcher: matcher) {
                updated.version = parsed
            }
            return ReconcileOutcome(assignmentID: input.assignmentID,
                                    installed: updated,
                                    change: .unchanged,
                                    previousFileName: existing.fileName)
        }
        // An exact hit on the latest release's filename inherits that release's
        // version even when the provider exposes no filename pattern.
        let resolved = chosen == input.usableReleaseFileName
            ? (input.releaseVersion ?? version(of: chosen, matcher: matcher))
            : version(of: chosen, matcher: matcher)
        let installed = InstalledISO(fileName: chosen, version: resolved,
                                     placedByApp: false, updatedAt: now)
        return ReconcileOutcome(assignmentID: input.assignmentID,
                                installed: installed,
                                change: .discovered,
                                previousFileName: input.installed?.fileName)
    }
}
