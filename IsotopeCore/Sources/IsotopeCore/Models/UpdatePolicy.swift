import Foundation

/// What Isotope is allowed to do with one assignment's ISO (PRD F33).
///
/// `trackLatest` is the v1 behaviour: the assignment is compared against the
/// latest release, counted in "N updates available" and updated on confirmation.
/// `keepAsIs` pins the assignment: its file is never touched, it is never
/// counted as stale, and it never triggers a drive-connect notification. Pinning
/// is what lets several versions of the same OS live on one Ventoy stick (F34).
public enum UpdatePolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case trackLatest
    case keepAsIs

    /// Assignments written before v1.2 have no `updatePolicy` field at all, and
    /// every one of them was tracking the latest release.
    public static let migrationDefault: UpdatePolicy = .trackLatest

    public var isPinned: Bool { self == .keepAsIs }

    public var displayName: String {
        switch self {
        case .trackLatest: return "Track latest"
        case .keepAsIs: return "Keep as is (pin)"
        }
    }
}

/// PRD F34: what a drive is allowed to hold. Pure functions over a drive's
/// assignment list, so the rule is stated once and tested without an AppStore.
///
/// A drive may hold **several** assignments of the same entry+channel provided
/// **at most one** of them is `trackLatest` — two trackers of one channel would
/// fight over the same file, whereas a tracker plus any number of pinned copies
/// is exactly the "keep 22.04 while 24.04 follows the releases" case.
public enum AssignmentRules {
    /// True when a *new* assignment of `entryID`+`channelID` with `policy` may be
    /// added to `assignments`.
    public static func canAdd(entryID: String, channelID: String,
                              policy: UpdatePolicy = .trackLatest,
                              to assignments: [Assignment]) -> Bool {
        guard policy == .trackLatest else { return true }
        return !hasTracker(entryID: entryID, channelID: channelID, in: assignments)
    }

    /// True when an *existing* assignment may switch to `policy`. Pinning is
    /// always allowed; un-pinning only when nothing else already tracks that
    /// entry+channel.
    public static func canSetPolicy(_ policy: UpdatePolicy, forAssignmentID id: UUID,
                                    in assignments: [Assignment]) -> Bool {
        guard let assignment = assignments.first(where: { $0.id == id }) else { return false }
        guard policy == .trackLatest else { return true }
        return !hasTracker(entryID: assignment.entryID, channelID: assignment.channelID,
                           in: assignments, excluding: id)
    }

    private static func hasTracker(entryID: String, channelID: String,
                                   in assignments: [Assignment],
                                   excluding excluded: UUID? = nil) -> Bool {
        assignments.contains { assignment in
            assignment.id != excluded
                && assignment.entryID == entryID
                && assignment.channelID == channelID
                && assignment.updatePolicy == .trackLatest
        }
    }
}
