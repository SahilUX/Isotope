import Foundation

/// One line of the persistent activity log (`history.json`, PRD F24).
public struct HistoryEvent: Codable, Identifiable, Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case succeeded, failed, cancelled
    }

    public var id: UUID
    public var date: Date
    public var driveID: UUID?
    public var driveName: String
    public var entryID: String
    public var channelID: String
    public var fileName: String
    public var version: VersionToken?
    public var outcome: Outcome
    public var message: String?

    public init(id: UUID = UUID(), date: Date = Date(), driveID: UUID? = nil, driveName: String,
                entryID: String, channelID: String, fileName: String, version: VersionToken? = nil,
                outcome: Outcome, message: String? = nil) {
        self.id = id
        self.date = date
        self.driveID = driveID
        self.driveName = driveName
        self.entryID = entryID
        self.channelID = channelID
        self.fileName = fileName
        self.version = version
        self.outcome = outcome
        self.message = message
    }
}
