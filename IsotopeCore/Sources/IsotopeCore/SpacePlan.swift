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
    /// ISO and absurd next to a 12 MB one, so the margin is 5% of the transfer,
    /// capped at 64 MB.
    public static func margin(forRequired required: Int64) -> Int64 {
        min(defaultMarginBytes, max(0, required / 20))
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
