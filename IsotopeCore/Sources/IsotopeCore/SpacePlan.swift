import Foundation

/// The free-space pre-flight for one copy (PRD F18, DESIGN §6 "drive full").
///
/// Pure arithmetic so the awkward part — "it fits, but only if the old ISO goes
/// first" — is decided in one testable place rather than inside the copy loop.
public struct SpacePlan: Sendable, Equatable {
    /// Bytes the new ISO needs on the drive.
    public var requiredBytes: Int64
    /// `volumeAvailableCapacityForImportantUsage` right now.
    public var availableBytes: Int64
    /// Size of the old ISO this update replaces, when it will actually be
    /// deleted (zero when the drive keeps old versions — PRD F6).
    public var reclaimableBytes: Int64
    /// Slack left over so the copy does not fill the volume to the last byte.
    public var marginBytes: Int64

    public static let defaultMarginBytes: Int64 = 64 * 1024 * 1024

    /// Slack scaled to the file: 64 MB of headroom is sensible next to a 5 GB
    /// ISO and absurd next to a 12 MB one, so a small transfer gets 5% of
    /// itself and a large one gets 64 MB — or 1% where that is more.
    ///
    /// PRD F68: the 1% floor for large images is not arbitrary. An 8.47 GB ISO
    /// onto a stick reporting 8.5 GB free passed this pre-flight by a hair and
    /// then ran out at the very end, twelve minutes in. Free space on exFAT is
    /// approximate — cluster rounding, directory growth, the FAT itself — and
    /// 0.75% of headroom is inside that error. 1% of an 8.47 GB ISO is 85 MB,
    /// which turns a twelve-minute failure into an instant, accurate refusal.
    public static func margin(forRequired required: Int64) -> Int64 {
        guard required > 0 else { return 0 }
        let small = required / 20
        return small < defaultMarginBytes ? small : max(defaultMarginBytes, required / 100)
    }

    public init(requiredBytes: Int64, availableBytes: Int64,
                reclaimableBytes: Int64 = 0,
                marginBytes: Int64? = nil) {
        let marginBytes = marginBytes ?? SpacePlan.margin(forRequired: requiredBytes)
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
        self.reclaimableBytes = max(0, reclaimableBytes)
        self.marginBytes = max(0, marginBytes)
    }

    /// What the copy can use if the replaced ISO is deleted first.
    public var effectiveAvailableBytes: Int64 { availableBytes + reclaimableBytes }

    public var fits: Bool { shortfallBytes == 0 }

    /// Exact figure the error message quotes (DESIGN §6). Zero when it fits.
    public var shortfallBytes: Int64 {
        max(0, requiredBytes + marginBytes - effectiveAvailableBytes)
    }

    /// True when the copy only fits once the old ISO is gone. The engine then
    /// deletes it up front instead of after the copy — the alternative is a
    /// pre-flight that passes and a copy that runs out of space halfway.
    public var requiresReclaimFirst: Bool {
        fits && requiredBytes + marginBytes > availableBytes && reclaimableBytes > 0
    }
}
