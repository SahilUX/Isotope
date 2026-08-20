import Foundation

/// A download that was paused, failed or cut short by a quit, together with
/// enough context to offer "Resume" on the next launch (PRD F19, DESIGN §6
/// "app quit mid-download"). The `URLSession` resume blob itself lives beside
/// this record as `<id>.resume`; this is the human-meaningful half.
public struct InterruptedDownload: Codable, Identifiable, Hashable, Sendable {
    /// The cache key of the artifact being fetched — also the resume file's stem.
    public var id: String
    public var sourceURL: URL
    public var fileName: String
    public var sha256: String?
    public var expectedSizeBytes: Int64?
    public var bytesDownloaded: Int64
    /// What the download was for, so the resume offer can re-queue the update.
    public var driveID: UUID?
    public var driveName: String?
    public var entryID: String?
    public var channelID: String?
    public var assignmentID: UUID?
    public var interruptedAt: Date
    /// True when the user paused it deliberately rather than losing it to a
    /// crash, a network drop or a quit — the resume offer words itself differently.
    public var wasPaused: Bool

    public init(id: String, sourceURL: URL, fileName: String, sha256: String? = nil,
                expectedSizeBytes: Int64? = nil, bytesDownloaded: Int64 = 0,
                driveID: UUID? = nil, driveName: String? = nil, entryID: String? = nil,
                channelID: String? = nil, assignmentID: UUID? = nil,
                interruptedAt: Date = Date(), wasPaused: Bool = false) {
        self.id = id
        self.sourceURL = sourceURL
        self.fileName = fileName
        self.sha256 = sha256
        self.expectedSizeBytes = expectedSizeBytes
        self.bytesDownloaded = bytesDownloaded
        self.driveID = driveID
        self.driveName = driveName
        self.entryID = entryID
        self.channelID = channelID
        self.assignmentID = assignmentID
        self.interruptedAt = interruptedAt
        self.wasPaused = wasPaused
    }

    /// Progress to show next to the resume offer, when the size is known.
    public var fractionCompleted: Double? {
        guard let expectedSizeBytes, expectedSizeBytes > 0 else { return nil }
        return min(1, max(0, Double(bytesDownloaded) / Double(expectedSizeBytes)))
    }
}
