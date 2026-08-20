import Foundation

/// A registered USB drive.
///
/// A `ventoy` drive is identified by volume UUID (BRD risk: reformat/rename); a
/// `flashed` drive is identified by its USB hardware identity, because flashing
/// destroys and recreates the volume (PRD F26/F27). The volume UUID of a flashed
/// drive is re-recorded after every flash, for display only.
public struct ManagedDrive: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var volumeUUID: String
    public var displayName: String
    /// Security-scoped bookmark granting access to the volume (PRD F1).
    /// Empty for flashed drives: they are written through the raw device, and
    /// no folder is ever chosen for them (PRD F28).
    public var bookmark: Data
    public var isoFolder: String        // relative path on the drive; "" = volume root
    public var keepOldVersions: Bool    // false = replace old ISO (PRD F6 default)
    public var assignments: [Assignment]
    public var lastSeenAt: Date?
    public var capacityBytes: Int64?

    // MARK: v1.1 (PRD §8)

    /// Ventoy (files on a volume) or flashed (the device *is* the image).
    public var kind: DriveKind
    /// Primary identity for flashed drives (PRD F27); nil for Ventoy drives.
    public var hardwareID: HardwareID?
    /// Last BSD name the device was seen at ("disk4"). Informational only —
    /// BSD names are reassigned freely and are never used as identity.
    public var lastBSDName: String?
    /// Set when a flash left the device half-written (DESIGN §9); cleared by the
    /// next successful flash.
    public var flashFailure: FlashFailure?

    public init(id: UUID = UUID(), volumeUUID: String, displayName: String, bookmark: Data,
                isoFolder: String = "", keepOldVersions: Bool = false,
                assignments: [Assignment] = [], lastSeenAt: Date? = nil,
                capacityBytes: Int64? = nil, kind: DriveKind = .ventoy,
                hardwareID: HardwareID? = nil, lastBSDName: String? = nil,
                flashFailure: FlashFailure? = nil) {
        self.id = id
        self.volumeUUID = volumeUUID
        self.displayName = displayName
        self.bookmark = bookmark
        self.isoFolder = isoFolder
        self.keepOldVersions = keepOldVersions
        self.assignments = assignments
        self.lastSeenAt = lastSeenAt
        self.capacityBytes = capacityBytes
        self.kind = kind
        self.hardwareID = hardwareID
        self.lastBSDName = lastBSDName
        self.flashFailure = flashFailure
    }

    /// Written by hand rather than synthesised: a synthesised decoder does not
    /// fall back to a property's default value, so every `drives.json` written
    /// before v1.1 — which has no `kind` at all — would fail to load
    /// (`DriveKind.migrationDefault` is what makes those drives Ventoy drives).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        volumeUUID = try c.decode(String.self, forKey: .volumeUUID)
        displayName = try c.decode(String.self, forKey: .displayName)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark) ?? Data()
        isoFolder = try c.decodeIfPresent(String.self, forKey: .isoFolder) ?? ""
        keepOldVersions = try c.decodeIfPresent(Bool.self, forKey: .keepOldVersions) ?? false
        assignments = try c.decodeIfPresent([Assignment].self, forKey: .assignments) ?? []
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        capacityBytes = try c.decodeIfPresent(Int64.self, forKey: .capacityBytes)
        kind = try c.decodeIfPresent(DriveKind.self, forKey: .kind) ?? DriveKind.migrationDefault
        hardwareID = try c.decodeIfPresent(HardwareID.self, forKey: .hardwareID)
        lastBSDName = try c.decodeIfPresent(String.self, forKey: .lastBSDName)
        flashFailure = try c.decodeIfPresent(FlashFailure.self, forKey: .flashFailure)
    }
}

public extension ManagedDrive {
    var isFlashed: Bool { kind == .flashed }

    /// PRD F26: the one assignment a flashed drive carries.
    var singleAssignment: Assignment? { isFlashed ? assignments.first : nil }

    /// The invariant, as the UI asks it before offering "Add Assignment".
    var canAddAssignment: Bool { kind.allowsMultipleAssignments || assignments.isEmpty }

    /// Enforces PRD F26 at the model level. Anything that builds a drive from
    /// outside (decoding a hand-edited `drives.json`, a UI bug) is normalised
    /// rather than trusted: a flashed drive keeps its first assignment only.
    mutating func enforceAssignmentInvariant() {
        guard isFlashed, assignments.count > 1 else { return }
        assignments = [assignments[0]]
    }

    func enforcingAssignmentInvariant() -> ManagedDrive {
        var copy = self
        copy.enforceAssignmentInvariant()
        return copy
    }

    /// A flashed stick whose last flash failed is in an undefined state — it is
    /// never "up to date", whatever the version comparison says (DESIGN §9).
    func displayedStaleness(_ base: Staleness) -> Staleness {
        // PRD F37: a pinned image is never presented as needing a reflash. The
        // failure itself still shows — `status(of:)` reports "needs attention"
        // off `flashFailure` directly, and the detail view banners it.
        guard isFlashed, flashFailure != nil, base != .pinned else { return base }
        return .stale
    }
}

/// (drive, catalog entry, channel) plus what is currently on the drive.
public struct Assignment: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var entryID: String
    public var channelID: String
    public var installed: InstalledISO?   // nil = not yet placed
    /// PRD F33; `trackLatest` unless the user pinned this one.
    public var updatePolicy: UpdatePolicy

    public init(id: UUID = UUID(), entryID: String, channelID: String,
                installed: InstalledISO? = nil,
                updatePolicy: UpdatePolicy = .trackLatest) {
        self.id = id
        self.entryID = entryID
        self.channelID = channelID
        self.installed = installed
        self.updatePolicy = updatePolicy
    }

    /// Hand-written for the same reason `ManagedDrive`'s is: a synthesised
    /// decoder does not fall back to a property's default, so every assignment
    /// written before v1.2 — none of which has `updatePolicy` — would fail to
    /// load (`UpdatePolicy.migrationDefault` makes them all trackers).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        entryID = try c.decode(String.self, forKey: .entryID)
        channelID = try c.decode(String.self, forKey: .channelID)
        installed = try c.decodeIfPresent(InstalledISO.self, forKey: .installed)
        updatePolicy = try c.decodeIfPresent(UpdatePolicy.self, forKey: .updatePolicy)
            ?? UpdatePolicy.migrationDefault
    }

    public var releaseKey: ReleaseKey { ReleaseKey(entryID: entryID, channelID: channelID) }

    public var isPinned: Bool { updatePolicy.isPinned }
}

public struct InstalledISO: Codable, Hashable, Sendable {
    public var fileName: String
    public var version: VersionToken?   // nil = filename not recognized
    /// false = discovered by a drive scan; true = written by Isotope (PRD F7/F22).
    public var placedByApp: Bool
    public var updatedAt: Date
    /// The build the image records *inside itself* ("26200.9168"), where the
    /// image has one to give: Windows media is named for its feature release
    /// only, and Microsoft refreshes the media without renaming it, so the
    /// filename cannot tell one 25H2 ISO from another. Read from the image on
    /// the drive, never guessed; nil for everything that is not Windows media
    /// and for media that has not been inspected (or would not say).
    public var build: String?

    public init(fileName: String, version: VersionToken? = nil, placedByApp: Bool,
                updatedAt: Date = Date(), build: String? = nil) {
        self.fileName = fileName
        self.version = version
        self.placedByApp = placedByApp
        self.updatedAt = updatedAt
        self.build = build
    }

    /// The recorded build as a comparable token (`.semantic([26200, 9168])`).
    public var buildToken: VersionToken? { build.flatMap(VersionToken.parse) }

    /// How the installed side of a row reads: "24.04.4", or "25H2 (build
    /// 26200.6584)" where the image told us its build, or the bare filename
    /// when the version could not be recognised at all. Mirrors
    /// `Release.displayVersion`, so both sides of "installed → latest" are
    /// formatted by the same rule.
    public var displayVersion: String {
        guard let version = version?.raw else { return fileName }
        guard let build, !build.isEmpty else { return version }
        return "\(version) (build \(build))"
    }
}
