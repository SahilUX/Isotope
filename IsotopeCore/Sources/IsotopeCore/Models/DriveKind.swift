import Foundation

/// How a managed drive holds its ISOs (PRD F26).
///
/// `ventoy` is the v1 behaviour: a mounted volume with ISO *files* on it.
/// `flashed` is a stick whose whole device *is* one ISO image, so updating it
/// means re-imaging the device (PRD §8).
public enum DriveKind: String, Codable, CaseIterable, Hashable, Sendable {
    case ventoy
    case flashed

    /// Registrations written before v1.1 have no `kind` field at all.
    public static let migrationDefault: DriveKind = .ventoy

    public var displayName: String {
        switch self {
        case .ventoy: return "Ventoy drive"
        case .flashed: return "Flashed drive"
        }
    }

    /// PRD F26: a flashed drive carries exactly one assignment — the image the
    /// whole device is written from.
    public var allowsMultipleAssignments: Bool { self == .ventoy }
}

/// A flash that did not finish leaves the stick in an undefined state: part of
/// the old image, part of the new one, and very possibly unbootable. That is not
/// an error the app may forget after the alert is dismissed, so it is recorded
/// on the drive until a later flash succeeds (DESIGN §9 "failure handling").
public struct FlashFailure: Codable, Hashable, Sendable {
    public var reason: String
    public var date: Date

    public init(reason: String, date: Date = Date()) {
        self.reason = reason
        self.date = date
    }

    /// What the drive list and detail view say about the stick.
    public var message: String {
        "The last flash did not finish, so this device is in an undefined state and will not boot reliably. Flash it again. (\(reason))"
    }
}
