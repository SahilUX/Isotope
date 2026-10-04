import Foundation
import IsotopeCore

/// PRD F4 and friends: something about a registered drive needs the user's attention.
enum DriveIssue: Equatable, Sendable {
    /// A volume mounted where this drive's bookmark points, but its UUID differs —
    /// the stick was reformatted or replaced (PRD F4).
    case changed(volumeName: String, foundUUID: String?)
    /// The drive is mounted but its ISO folder could not be read.
    case unreadable(String)
    /// PRD F40: a registered *flashed* stick whose volume label no longer looks
    /// like the image it is recorded as holding — it was re-flashed elsewhere.
    case contentsChanged(label: String, expected: String)

    var message: String {
        switch self {
        case .changed(let name, let found):
            let identity = found.map { "now identifies as \($0)" } ?? "no longer reports a volume UUID"
            return "The volume “\(name)” \(identity), which does not match this registration. It was probably reformatted or replaced. Unregister this drive and register it again — no files were touched."
        case .unreadable(let detail):
            return detail
        case .contentsChanged(let label, let expected):
            return "This device now reports the volume “\(label)”, which does not look like \(expected). It was probably written with something else. Change the image below to match, or flash it again — nothing on it has been touched."
        }
    }
}

/// The dot next to a drive in the sidebar and list (DESIGN §5, PRD F2/F42).
///
/// PRD F42 fixes what the dot means: **grey is strictly "not connected"**. A
/// connected drive is orange when something is stale and green otherwise —
/// including the states that used to fall through to grey: no assignments yet,
/// nothing checked yet, an installed filename with no comparable version.
enum DriveStatus: Equatable {
    case disconnected
    case needsAttention
    case upToDate
    case updates(Int)
    /// Connected, nothing stale, but at least one assignment could not be
    /// compared (never checked, or an unrecognised installed version) or there
    /// is nothing assigned at all. Green, with its own wording (PRD F42).
    case unknown

    var summary: String {
        switch self {
        case .disconnected: return "Not connected"
        case .needsAttention: return "Needs attention"
        case .upToDate: return "Up to date"
        case .updates(let count): return "\(count) update\(count == 1 ? "" : "s") available"
        case .unknown: return "Nothing to update"
        }
    }
}

enum DriveRegistrationError: LocalizedError, Equatable {
    case alreadyRegistered(String)
    case noVolumeUUID(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRegistered(let name):
            return "“\(name)” is already registered. Select it in the sidebar to change its assignments."
        case .noVolumeUUID(let name):
            return DriveAccessError.noVolumeUUID(name).errorDescription
        case .unreadable(let detail):
            return "The volume could not be read: \(detail)"
        }
    }
}

// MARK: - Drive registration, connection state, scanning

extension AppStore {
    // MARK: Derived

    func drive(id: UUID) -> ManagedDrive? { drives.first { $0.id == id } }

    func volumeInfo(for drive: ManagedDrive) -> VolumeInfo? { connectedVolumes[drive.volumeUUID] }

    /// PRD F27: a flashed drive is "connected" when its *device* is attached —
    /// there may be no mounted volume at all (a freshly flashed Linux image
    /// often exposes nothing macOS mounts).
    func isConnected(_ drive: ManagedDrive) -> Bool {
        switch drive.kind {
        case .ventoy: return connectedVolumes[drive.volumeUUID] != nil
        case .flashed: return attachedDevice(for: drive) != nil
        }
    }

    func status(of drive: ManagedDrive) -> DriveStatus {
        if driveIssues[drive.id] != nil { return .needsAttention }
        // DESIGN §9: a half-written stick is an attention case, not an update.
        if drive.flashFailure != nil { return .needsAttention }
        guard isConnected(drive) else { return .disconnected }
        let stale = staleAssignments(on: drive).count
        if stale > 0 { return .updates(stale) }
        // PRD F42: from here on the drive is connected with nothing stale, so
        // the dot is green either way. `.upToDate` is claimed only when every
        // assignment was actually compared; the rest — no assignments yet, a
        // channel that has not been checked, an installed file whose version
        // could not be parsed — report `.unknown`, which is *also* green.
        // Neither may ever be grey: grey means unplugged.
        guard !drive.assignments.isEmpty else { return .unknown }
        let comparable = drive.assignments.allSatisfy { staleness(of: $0, on: drive) != .unknown }
        return comparable ? .upToDate : .unknown
    }

    /// PRD F23 / F5: destructive-ish actions wait for the pipeline to settle.
    func hasOperationsInFlight(_ drive: ManagedDrive) -> Bool {
        drivesWithOperationsInFlight.contains(drive.id)
    }

    /// Entry + channel pairs a drive is assigned, for targeted catalog checks.
    func channelJobs(for drive: ManagedDrive) -> [(key: ReleaseKey, config: ProviderConfig)] {
        drive.assignments.compactMap { assignment in
            guard let entry = entry(id: assignment.entryID),
                  let channel = entry.channel(id: assignment.channelID) else { return nil }
            return (assignment.releaseKey, channel.provider)
        }
    }

    /// True when any of this drive's channels has no cached release, or one
    /// older than `maxAge` (DESIGN §4.3: check on mount only if the cache is stale).
    func releaseCacheIsStale(for drive: ManagedDrive, maxAge: TimeInterval = 6 * 60 * 60,
                             now: Date = Date()) -> Bool {
        drive.assignments.contains { assignment in
            guard let cached = release(for: assignment) else { return true }
            return now.timeIntervalSince(cached.checkedAt) > maxAge
        }
    }

    // MARK: Registration (PRD F1)

    /// Registers a mounted volume. `url` must come from the open panel so the
    /// sandbox grants a security-scoped bookmark (PRD N2).
    @discardableResult
    func registerDrive(at url: URL) throws -> ManagedDrive {
        let info: VolumeInfo
        do {
            info = try driveProbe.info(url)
        } catch {
            throw DriveRegistrationError.unreadable(error.localizedDescription)
        }
        guard let volumeUUID = info.volumeUUID, !volumeUUID.isEmpty else {
            throw DriveRegistrationError.noVolumeUUID(info.name)
        }
        if let existing = drives.first(where: { $0.volumeUUID == volumeUUID }) {
            throw DriveRegistrationError.alreadyRegistered(existing.displayName)
        }
        let bookmark: Data
        do {
            bookmark = try driveProbe.bookmark(url)
        } catch {
            throw DriveRegistrationError.unreadable(error.localizedDescription)
        }
        let drive = ManagedDrive(volumeUUID: volumeUUID,
                                 displayName: info.name,
                                 bookmark: bookmark,
                                 lastSeenAt: Date(),
                                 capacityBytes: info.capacityBytes)
        addDrive(drive)
        connectedVolumes[volumeUUID] = info
        return drive
    }

    /// PRD F5: stops tracking. Files on the drive are never touched.
    func unregisterDrive(id: UUID) {
        forgetWindowsBuildAttempts(on: id)
        removeDrive(id: id)
        driveIssues[id] = nil
        unknownISOFiles[id] = nil
        detectedISOsByDrive[id] = nil
        isoSizes[id] = nil
        lastScanAt[id] = nil
        isScanning.remove(id)
        if selection == .drive(id) { selection = .drives }
    }

    // MARK: Connection state (PRD F2/F3)

    func markConnected(_ drive: ManagedDrive, info: VolumeInfo, at date: Date = Date()) {
        connectedVolumes[drive.volumeUUID] = info
        driveIssues[drive.id] = nil
        // A reconnect is the natural moment to retry anything that could not be
        // read last time — an inspection interrupted by an unplug (PRD F43
        // addendum) should not leave that file unreadable forever.
        forgetWindowsBuildAttempts(on: drive.id)
        var updated = drive
        updated.lastSeenAt = date
        updated.capacityBytes = info.capacityBytes ?? drive.capacityBytes
        // A renamed stick keeps its identity (the UUID) but shows its new name.
        if !info.name.isEmpty { updated.displayName = info.name }
        updateDrive(updated)
    }

    func markDisconnected(volumeUUID: String) {
        connectedVolumes[volumeUUID] = nil
        for drive in drives where drive.volumeUUID == volumeUUID {
            isScanning.remove(drive.id)
        }
    }

    func setIssue(_ issue: DriveIssue?, for driveID: UUID) {
        driveIssues[driveID] = issue
    }

    // MARK: Scan & reconcile (PRD F7)

    /// Flattens a drive's assignments into the pure reconciler's input.
    func reconcileInputs(for drive: ManagedDrive) -> [ReconcileInput] {
        drive.assignments.map { assignment in
            let channel = entry(id: assignment.entryID)?.channel(id: assignment.channelID)
            let cached = release(for: assignment)
            return ReconcileInput(assignmentID: assignment.id,
                                  fileNamePattern: channel?.provider.fileNamePattern,
                                  releaseFileName: cached?.fileName,
                                  releaseVersion: cached?.version,
                                  installed: assignment.installed,
                                  isPinned: assignment.isPinned)
        }
    }

    /// Reads the drive's ISO folder and reconciles it against the assignments.
    /// Returns nil when the drive is not mounted or its folder cannot be read
    /// (the issue is recorded on the drive instead).
    @discardableResult
    func scanAndReconcile(driveID: UUID, now: Date = Date()) -> ReconcileResult? {
        // A flashed drive has no ISO folder to scan: the device *is* the image,
        // and what is installed on it is only ever what Isotope wrote (PRD F26).
        guard let drive = drive(id: driveID), !drive.isFlashed, isConnected(drive) else { return nil }
        isScanning.insert(driveID)
        defer { isScanning.remove(driveID) }
        let fileNames: [String]
        do {
            fileNames = try driveProbe.listISOs(drive.bookmark, drive.isoFolder)
        } catch {
            setIssue(.unreadable("The ISO folder could not be read: \(error.localizedDescription)"), for: driveID)
            return nil
        }
        if case .unreadable = driveIssues[driveID] { setIssue(nil, for: driveID) }
        let result = DriveReconciler.reconcile(fileNames: fileNames,
                                               assignments: reconcileInputs(for: drive),
                                               now: now)
        apply(result, to: driveID)
        // Phase 4: a tracked ISO that disappeared is worth a history line (F24).
        recordReconcileHistory(result, driveID: driveID)
        // PRD F43 addendum: Windows media names its feature release and not its
        // build, so anything newly found here still has to be opened to say
        // which 25H2 it is. Runs on its own, after the scan has settled.
        refreshWindowsBuilds(driveID: driveID)
        return result
    }

    /// Writes a reconcile result back onto the drive's assignments.
    func apply(_ result: ReconcileResult, to driveID: UUID) {
        guard var drive = drive(id: driveID) else { return }
        for outcome in result.outcomes {
            guard let index = drive.assignments.firstIndex(where: { $0.id == outcome.assignmentID })
            else { continue }
            drive.assignments[index].installed = outcome.installed
        }
        drive.lastSeenAt = result.scannedAt
        updateDrive(drive)
        unknownISOFiles[driveID] = result.unknownFiles
        refreshDetectedISOs(driveID: driveID)
        lastScanAt[driveID] = result.scannedAt
        // PRD F60: sizes come from the same scan, so what the rows show is
        // always what the last listing actually saw.
        isoSizes[driveID] = driveProbe.isoSizes(drive.bookmark, drive.isoFolder)
    }

    // MARK: Content auto-detect (PRD F41)

    /// Unclaimed `.iso` files on a Ventoy drive that the catalog recognises.
    ///
    /// Still derived from the scan's own output — `unknownISOFiles` — so the
    /// offers cannot drift out of step with what is on the drive. What changed
    /// (PRD F62) is *when*: once per scan, rather than on every read. Views read
    /// this many times a second while a copy reports progress, and the matching
    /// behind it is not free.
    func detectedISOs(on drive: ManagedDrive) -> [DetectedISO] {
        guard !drive.isFlashed else { return [] }
        return detectedISOsByDrive[drive.id] ?? []
    }

    /// The rest of the unknown files — listed informationally, exactly as before
    /// (PRD F7/F22): Isotope never touches them.
    func unrecognizedISOFiles(on drive: ManagedDrive) -> [String] {
        let recognized = Set(detectedISOs(on: drive).map(\.fileName))
        return (unknownISOFiles[drive.id] ?? []).filter { !recognized.contains($0) }
    }

    /// Recomputes the detection for one drive, or for every drive when the
    /// catalog itself changed. The only place the matcher runs.
    func refreshDetectedISOs(driveID: UUID? = nil) {
        let targets = driveID.map { [$0] } ?? drives.map(\.id)
        for id in targets {
            guard let drive = drive(id: id), !drive.isFlashed else {
                detectedISOsByDrive[id] = nil
                continue
            }
            let unclaimed = unknownISOFiles[id] ?? []
            detectedISOsByDrive[id] = unclaimed.isEmpty
                ? []
                : ISOContentMatcher.detect(unclaimedFiles: unclaimed, in: allEntries)
        }
    }

    /// The channels a detection may be assigned to: the one that matched, or —
    /// when several channels of the entry share a filename pattern (Ubuntu's LTS
    /// and Latest) — all of the matching ones, for the user to pick from.
    func channels(for detected: DetectedISO) -> [Channel] {
        guard let entry = entry(id: detected.entryID) else { return [] }
        if let channelID = detected.channelID {
            return entry.channel(id: channelID).map { [$0] } ?? []
        }
        let ids = ISOContentMatcher.matchingChannelIDs(fileName: detected.fileName, entry: entry)
        return ids.compactMap { entry.channel(id: $0) }
    }

    /// PRD F34, as the offer buttons ask it: "Track latest" is only offered when
    /// nothing already tracks that entry+channel; "Pin as is" always is.
    func canAdopt(_ detected: DetectedISO, channelID: String, policy: UpdatePolicy,
                  on drive: ManagedDrive) -> Bool {
        canAssign(entryID: detected.entryID, channelID: channelID, policy: policy, to: drive)
    }

    /// PRD F41: create the assignment the user chose for a detected file, with
    /// that file recorded as installed. Nothing is ever created silently, and
    /// nothing on the drive is written — the file is simply claimed, so the next
    /// scan stops offering it.
    @discardableResult
    func adoptDetectedISO(_ detected: DetectedISO, channelID: String, policy: UpdatePolicy,
                          on driveID: UUID, now: Date = Date()) -> Assignment? {
        guard var target = drive(id: driveID), !target.isFlashed,
              (unknownISOFiles[driveID] ?? []).contains(detected.fileName),
              canAdopt(detected, channelID: channelID, policy: policy, on: target)
        else { return nil }
        let installed = InstalledISO(fileName: detected.fileName, version: detected.version,
                                     placedByApp: false, updatedAt: now)
        let assignment = Assignment(entryID: detected.entryID, channelID: channelID,
                                    installed: installed, updatePolicy: policy)
        target.assignments.append(assignment)
        updateDrive(target)
        // Reconcile immediately so the file is claimed and drops out of the
        // offers. If the drive went away between the scan and the click, claim
        // it locally instead — the next real scan settles it either way.
        if scanAndReconcile(driveID: driveID, now: now) == nil {
            unknownISOFiles[driveID]?.removeAll { $0 == detected.fileName }
            refreshDetectedISOs(driveID: driveID)
        }
        // A new tracker may have something to announce on the next connect.
        lastAnnouncedUpdates[driveID] = nil
        return drive(id: driveID)?.assignments.first { $0.id == assignment.id }
    }

    // MARK: Assignments

    /// PRD F34: a drive may hold several assignments of one entry+channel as
    /// long as at most one of them tracks the latest release. The rule itself is
    /// a pure function in IsotopeCore (`AssignmentRules`).
    func canAssign(entryID: String, channelID: String, policy: UpdatePolicy = .trackLatest,
                   to drive: ManagedDrive) -> Bool {
        // PRD F26: a flashed drive holds exactly one image; the detail view
        // offers "Change image" rather than a second assignment.
        guard drive.canAddAssignment else { return false }
        return AssignmentRules.canAdd(entryID: entryID, channelID: channelID, policy: policy,
                                      to: drive.assignments)
    }

    @discardableResult
    func addAssignment(entryID: String, channelID: String, to driveID: UUID,
                       policy: UpdatePolicy = .trackLatest) -> Assignment? {
        guard var drive = drive(id: driveID),
              canAssign(entryID: entryID, channelID: channelID, policy: policy, to: drive)
        else { return nil }
        let assignment = Assignment(entryID: entryID, channelID: channelID, updatePolicy: policy)
        drive.assignments.append(assignment)
        updateDrive(drive)
        // A brand-new assignment may already have a file sitting on the drive.
        scanAndReconcile(driveID: driveID)
        return assignment
    }

    /// PRD F33/F36: pin an assignment or hand it back to the update pipeline.
    /// Staleness is derived, never stored, so un-pinning re-evaluates on the
    /// next read with no extra bookkeeping.
    @discardableResult
    func setUpdatePolicy(_ policy: UpdatePolicy, forAssignment assignmentID: UUID,
                         on driveID: UUID) -> Bool {
        guard var drive = drive(id: driveID),
              let index = drive.assignments.firstIndex(where: { $0.id == assignmentID }),
              drive.assignments[index].updatePolicy != policy,
              AssignmentRules.canSetPolicy(policy, forAssignmentID: assignmentID,
                                           in: drive.assignments)
        else { return false }
        drive.assignments[index].updatePolicy = policy
        updateDrive(drive)
        // A pinned assignment that becomes a tracker again may be announced on
        // the next connect; forget what was last said about this drive.
        lastAnnouncedUpdates[driveID] = nil
        return true
    }

    /// Whether the row's "Track latest" option is offered (PRD F34): only one
    /// assignment of an entry+channel may track.
    func canTrackLatest(assignmentID: UUID, on drive: ManagedDrive) -> Bool {
        AssignmentRules.canSetPolicy(.trackLatest, forAssignmentID: assignmentID,
                                     in: drive.assignments)
    }

    /// Removes tracking for one assignment. By default the ISO stays on the
    /// drive (PRD F22) and shows up under "Found on this drive" on the next
    /// scan; `deletingFile` deletes it first (PRD F71). If that delete fails the
    /// assignment is kept, so the row the user acted on is still there.
    func removeAssignment(id assignmentID: UUID, from driveID: UUID, deletingFile: Bool = false) throws {
        guard var drive = drive(id: driveID),
              let assignment = drive.assignments.first(where: { $0.id == assignmentID }) else { return }
        if deletingFile, let fileName = assignment.installed?.fileName {
            try deleteISO(fileName: fileName, on: driveID, removingAssignment: assignment, rescan: false)
            drive = self.drive(id: driveID) ?? drive
        }
        drive.assignments.removeAll { $0.id == assignmentID }
        updateDrive(drive)
        scanAndReconcile(driveID: driveID)
    }

    // MARK: Deleting ISOs (PRD F71)

    /// Why `fileName` cannot be deleted from `drive` right now, or nil when it
    /// can. The view disables the action and shows this as its help.
    /// `assignmentID` is the row being removed along with the file: it is the
    /// one holder of the file that does not count against deleting it.
    func deleteBlocker(fileName: String?, on drive: ManagedDrive, assignmentID: UUID? = nil) -> String? {
        guard let fileName else { return "Nothing is installed for this assignment" }
        guard let info = volumeInfo(for: drive) else { return "Connect the drive to delete its files" }
        if info.isReadOnly { return "The drive is mounted read-only" }
        if hasOperationsInFlight(drive) { return "Wait for the drive's updates to finish" }
        // A pinned copy and a tracker can hold one file between them (an
        // adopted ISO that was then assigned again); removing one row must not
        // pull the file out from under the other.
        let holders = drive.assignments.filter { $0.installed?.fileName == fileName && $0.id != assignmentID }
        if !holders.isEmpty { return "An assignment on this drive still uses this file" }
        return nil
    }

    /// Deletes one ISO from a connected drive, records it in Activity, and
    /// rescans. A file an assignment still holds is refused unless that
    /// assignment is the one being removed with it.
    func deleteISO(fileName: String, on driveID: UUID, removingAssignment assignment: Assignment? = nil,
                   rescan: Bool = true) throws {
        guard let drive = drive(id: driveID) else { return }
        if let reason = deleteBlocker(fileName: fileName, on: drive, assignmentID: assignment?.id) {
            throw ISODeletionError.blocked(reason)
        }
        let size = isoSize(fileName: fileName, on: driveID)
        try driveProbe.deleteISO(drive.bookmark, drive.isoFolder, fileName)
        let freed = size.map { " · freed \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? ""
        appendHistory(HistoryEvent(driveID: driveID, driveName: drive.displayName,
                                   entryID: assignment?.entryID ?? "", channelID: assignment?.channelID ?? "",
                                   fileName: fileName, version: assignment?.installed?.version,
                                   outcome: .succeeded,
                                   message: "Deleted \(fileName)\(freed)"))
        if rescan { scanAndReconcile(driveID: driveID) }
    }

    // MARK: Per-drive settings (PRD F6)

    func setISOFolder(_ folder: String, for driveID: UUID) {
        guard var drive = drive(id: driveID), drive.isoFolder != folder else { return }
        drive.isoFolder = folder
        updateDrive(drive)
        scanAndReconcile(driveID: driveID)
    }

    func setKeepOldVersions(_ keep: Bool, for driveID: UUID) {
        guard var drive = drive(id: driveID) else { return }
        drive.keepOldVersions = keep
        updateDrive(drive)
    }

    // MARK: Eject (PRD F23)

    /// Whether the sidebar's eject button is live: something is attached to
    /// eject, and nothing is being written to it (PRD F23).
    func canEject(_ drive: ManagedDrive) -> Bool {
        guard !hasOperationsInFlight(drive) else { return false }
        return drive.isFlashed ? attachedDevice(for: drive) != nil : volumeInfo(for: drive) != nil
    }

    /// One eject for either kind of drive, for callers that do not care which.
    func ejectAnyDrive(driveID: UUID) throws {
        guard let drive = drive(id: driveID) else { return }
        if drive.isFlashed { ejectFlashedDrive(driveID: driveID) } else { try eject(driveID: driveID) }
    }

    func eject(driveID: UUID) throws {
        guard let drive = drive(id: driveID) else { return }
        guard !hasOperationsInFlight(drive) else { return }
        guard let info = volumeInfo(for: drive) else { return }
        try DriveAccess.eject(volumeURL: info.url)
        markDisconnected(volumeUUID: drive.volumeUUID)
    }
}

enum ISODeletionError: LocalizedError, Equatable {
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .blocked(let reason): return "The ISO was not deleted: \(reason.lowercased())."
        }
    }
}
