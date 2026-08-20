import AppKit
import Foundation
import IsotopeCore

// MARK: - Registration errors (PRD F28)

enum FlashRegistrationError: LocalizedError, Equatable {
    case alreadyRegistered(String)
    case noHardwareIdentity(String)
    case ineligible(FlashGateFailure)

    var errorDescription: String? {
        switch self {
        case .alreadyRegistered(let name):
            return "“\(name)” is already registered. Select it in the sidebar to change what it holds."
        case .noHardwareIdentity(let name):
            return "“\(name)” does not report a USB identity, so Isotope could not recognise it again after a flash. Try a different port, or use it as a Ventoy drive instead."
        case .ineligible(let failure):
            return failure.reason
        }
    }
}

// MARK: - Contents re-check (PRD F40)

/// What an attach-time label comparison concluded. Returned rather than only
/// applied so the behaviour is assertable without a USB stick.
enum FlashedContentsOutcome: Equatable {
    /// No labels, or no pattern for this entry — nothing can be concluded.
    case noEvidence
    /// Still the recorded image, at the recorded version.
    case unchanged
    /// Still the recorded image, but a different version is on the stick now.
    case versionUpdated(VersionToken)
    /// The labels no longer look like the recorded image at all.
    case contentsChanged
}

// MARK: - Confirmation plan (PRD F29/F30)

/// What the flash confirmation dialog spells out before a single byte is
/// written. Built on the main actor from current device state, and re-checked by
/// the engine at flash time — this is a display object, never a permission.
struct FlashPlan: Identifiable, Sendable {
    var id = UUID()
    var driveID: UUID
    var driveName: String
    var assignmentID: UUID
    var entryID: String
    var channelID: String
    var title: String
    var release: Release
    var device: FlashDevice
    var fromVersion: String?
    var toVersion: String
    var fileName: String
    var isoSizeBytes: Int64?
    /// PRD F21: no published checksum → the dialog says "unverified".
    var isVerifiable: Bool
    /// Non-nil when a gate already refuses this device; the dialog shows the
    /// reason and offers no Flash button.
    var gateFailure: FlashGateFailure?

    var deviceSizeBytes: Int64 { device.sizeBytes }
    var canFlash: Bool { gateFailure == nil }
}

// MARK: - Store surface

extension AppStore {
    // MARK: Attached devices (PRD F27)

    /// The physical device a registered flashed drive is currently attached at,
    /// matched by hardware identity rather than BSD name.
    func attachedDevice(for drive: ManagedDrive) -> FlashDevice? {
        guard drive.isFlashed else { return nil }
        return DeviceEnumerator.device(matching: drive, in: attachedDevices)
    }

    /// Devices that are eligible and not already registered — the registration
    /// picker's list (PRD F28).
    func registrableDevices() -> [FlashDevice] {
        attachedDevices.filter { device in
            device.isEligibleForRegistration && !drives.contains { drive in
                DeviceEnumerator.device(matching: drive, in: [device]) != nil
            }
        }
    }

    // MARK: Contents auto-detect (PRD F40)

    /// What a stick's volume labels say it holds. Nil when nothing matches or
    /// two different entries do — a wrong preselection in a flash confirmation
    /// is worse than none, so ambiguity is reported as "unknown".
    func detectedContents(for device: FlashDevice) -> VolumeLabelMatch? {
        VolumeLabelMatcher.bestMatch(labels: device.volumeNames, in: allEntries)
    }

    /// "Ubuntu Desktop (LTS) 24.04.4" for the registration list; nil when the
    /// stick's labels say nothing recognisable.
    func detectedContentsSummary(for device: FlashDevice) -> String? {
        guard let match = detectedContents(for: device), let entry = entry(id: match.entryID)
        else { return nil }
        var parts = [entry.name]
        if let channelID = match.channelID, let channel = entry.channel(id: channelID),
           entry.channels.count > 1 {
            parts.append("(\(channel.name))")
        }
        if let version = match.version { parts.append(version.raw) }
        return parts.joined(separator: " ")
    }

    /// PRD F40 + F44, attach path: compare what a registered flashed drive
    /// *currently* looks like — its volume labels, and any version a content
    /// probe read off the mounted volume — against what it is recorded as
    /// holding.
    ///
    /// Precedence for "what version is on this stick":
    ///  1. what Isotope recorded when it flashed the stick itself — the baseline
    ///     that stands unless newer evidence appears;
    ///  2. `probedVersion`, a marker file read from the volume (F44). It wins
    ///     over the label because it is the image talking rather than a name
    ///     that may carry no version at all — Proxmox VE's label is "PVE";
    ///  3. the volume label (F40);
    ///  4. nothing, and the recorded version stands untouched.
    ///
    /// Three honest outcomes, and one non-answer: a stick whose image macOS does
    /// not mount reports no labels and no readable files at all, and silence is
    /// not evidence that the contents changed.
    @discardableResult
    func reconcileFlashedContents(driveID: UUID, labels: [String],
                                  probedVersion: VersionToken? = nil,
                                  now: Date = Date()) -> FlashedContentsOutcome {
        guard let drive = self.drive(id: driveID), drive.isFlashed,
              let assignment = drive.singleAssignment,
              let entry = entry(id: assignment.entryID)
        else { return .noEvidence }

        let hasLabelEvidence = entry.volumeLabelPattern(forChannel: assignment.channelID) != nil
            && !labels.isEmpty
        guard hasLabelEvidence || probedVersion != nil else { return .noEvidence }

        var match: VolumeLabelMatch?
        if hasLabelEvidence {
            guard let found = VolumeLabelMatcher.match(labels: labels, entry: entry,
                                                       channelID: assignment.channelID) else {
                setIssue(.contentsChanged(label: labels.joined(separator: ", "),
                                          expected: entry.name), for: driveID)
                return .contentsChanged
            }
            match = found
            // The stick is what it says it is again: retract any earlier warning.
            if case .contentsChanged = driveIssues[driveID] { setIssue(nil, for: driveID) }
        }

        guard let version = probedVersion ?? match?.version,
              version != assignment.installed?.version else { return .unchanged }
        var updated = drive
        guard let index = updated.assignments.firstIndex(where: { $0.id == assignment.id })
        else { return .unchanged }
        let previous = assignment.installed?.version?.raw ?? "nothing recorded"
        // The label is the more descriptive name when there is one; the probe
        // path records the file it read from instead, so history says where the
        // version came from.
        let source = match?.label ?? labels.first ?? "\(entry.name) volume contents"
        updated.assignments[index].installed = InstalledISO(fileName: source, version: version,
                                                            placedByApp: false, updatedAt: now)
        updateDrive(updated)
        appendHistory(HistoryEvent(date: now, driveID: driveID, driveName: drive.displayName,
                                   entryID: assignment.entryID, channelID: assignment.channelID,
                                   fileName: source, version: version, outcome: .succeeded,
                                   message: "“\(drive.displayName)” now reports \(entry.name) \(version.raw) (was \(previous)); Isotope did not write it."))
        return .versionUpdated(version)
    }

    /// PRD F44: the version a flashed drive's own marker files report, or nil
    /// when the entry declares no probes, nothing is mounted, or nothing parses.
    func probedVersion(for drive: ManagedDrive, device: FlashDevice) -> VersionToken? {
        guard drive.isFlashed, let assignment = drive.singleAssignment,
              let entry = entry(id: assignment.entryID) else { return nil }
        let probes = entry.contentProbes(forChannel: assignment.channelID)
        return VolumeContentProbe.version(probes: probes, volumes: device.volumeMountPoints)
    }

    // MARK: Registration (PRD F28)

    @discardableResult
    func registerFlashedDrive(device: FlashDevice, entryID: String, channelID: String,
                              detected: VolumeLabelMatch? = nil) throws
        -> ManagedDrive {
        if let failure = FlashSafetyGate.evaluate(device: device.gateDescription(), isoSizeBytes: nil) {
            throw FlashRegistrationError.ineligible(failure)
        }
        guard let hardwareID = device.hardwareID else {
            throw FlashRegistrationError.noHardwareIdentity(device.displayName)
        }
        if let existing = drives.first(where: {
            DeviceEnumerator.device(matching: $0, in: [device]) != nil
        }) {
            throw FlashRegistrationError.alreadyRegistered(existing.displayName)
        }
        // PRD F40: when the stick's label already identifies this image, record
        // it as installed rather than starting the drive at "never flashed".
        // `placedByApp: false` — Isotope did not write it, it only recognised it.
        let installed = detected.flatMap { match -> InstalledISO? in
            guard match.entryID == entryID else { return nil }
            return InstalledISO(fileName: match.label, version: match.version, placedByApp: false)
        }
        let drive = ManagedDrive(volumeUUID: device.volumeUUIDs.first ?? "",
                                 displayName: device.displayName,
                                 bookmark: Data(),           // PRD F28: no folder, no bookmark
                                 assignments: [Assignment(entryID: entryID, channelID: channelID,
                                                          installed: installed)],
                                 lastSeenAt: Date(),
                                 capacityBytes: device.sizeBytes,
                                 kind: .flashed,
                                 hardwareID: hardwareID,
                                 lastBSDName: device.bsdName)
        addDrive(drive)
        return drive
    }

    /// PRD F26: a flashed drive holds one image, so changing it replaces the
    /// assignment rather than adding a second one.
    func setFlashedAssignment(entryID: String, channelID: String, on driveID: UUID) {
        guard var drive = drive(id: driveID), drive.isFlashed else { return }
        guard drive.assignments.first?.entryID != entryID
                || drive.assignments.first?.channelID != channelID else { return }
        drive.assignments = [Assignment(entryID: entryID, channelID: channelID)]
        drive.enforceAssignmentInvariant()
        updateDrive(drive)
    }

    /// Entries a flashed drive may be assigned (PRD F32).
    var flashableEntries: [CatalogEntry] { FlashEligibility.flashableEntries(allEntries) }

    // MARK: Plans

    /// Builds the confirmation plan for a flashed drive's single assignment.
    /// Nil when the drive is not flashed, has no assignment, no resolved release
    /// or is not currently attached.
    func flashPlan(driveID: UUID) -> FlashPlan? {
        guard let drive = drive(id: driveID), drive.isFlashed,
              let assignment = drive.singleAssignment,
              let release = release(for: assignment),
              let device = attachedDevice(for: drive) else { return nil }
        let entry = entry(id: assignment.entryID)
        let channel = entry?.channel(id: assignment.channelID)
        guard channel?.provider.isFlashable != false else { return nil }
        let sizeBytes = release.sizeBytes
        return FlashPlan(driveID: drive.id,
                         driveName: drive.displayName,
                         assignmentID: assignment.id,
                         entryID: assignment.entryID,
                         channelID: assignment.channelID,
                         title: title(for: assignment),
                         release: release,
                         device: device,
                         fromVersion: assignment.installed?.displayVersion,
                         toVersion: release.displayVersion,
                         fileName: DownloadArtifact.placedFileName(for: release) ?? release.fileName,
                         isoSizeBytes: sizeBytes,
                         isVerifiable: release.isVerifiable,
                         gateFailure: FlashSafetyGate.evaluate(device: device.gateDescription(),
                                                               isoSizeBytes: sizeBytes))
    }

    /// PRD F30: this is only ever called from the confirmation dialog's own
    /// button. There is no code path that flashes without it.
    func startFlash(_ plan: FlashPlan, verify: Bool) {
        guard plan.canFlash, let engine = flashEngine else { return }
        let request = FlashRequest(driveID: plan.driveID, driveName: plan.driveName,
                                   assignmentID: plan.assignmentID, entryID: plan.entryID,
                                   channelID: plan.channelID, title: plan.title,
                                   release: plan.release, bsdName: plan.device.bsdName,
                                   deviceName: plan.device.displayName,
                                   verifyAfterWrite: verify)
        Task { await engine.enqueue(request) }
    }

    // MARK: Engine callbacks

    func beginFlashOperation(for request: FlashRequest) {
        let state = UpdateOperationState(
            id: request.id, driveID: request.driveID, driveName: request.driveName,
            assignmentID: request.assignmentID, entryID: request.entryID,
            channelID: request.channelID, title: request.title,
            fileName: DownloadArtifact.placedFileName(for: request.release) ?? request.release.fileName,
            version: request.release.version.raw,
            totalBytes: request.release.sizeBytes)
        operations.removeAll { $0.id == request.id }
        operations.append(state)
        drivesWithOperationsInFlight.insert(request.driveID)
        flashEjectOffers.remove(request.driveID)
    }

    /// Terminal step of a flash: drive record, history, in-flight flag,
    /// notification, eject offer (DESIGN §9 steps 7–8).
    func finishFlashOperation(request: FlashRequest, result: FlashOutcome) {
        var event: HistoryEvent
        switch result {
        case .success(let flashed):
            mutateFlashOperation(id: request.id) { operation in
                operation.phase = .completed
                operation.finishedAt = Date()
                operation.completedBytes = flashed.sizeBytes
                operation.totalBytes = flashed.sizeBytes
                operation.bytesPerSecond = nil
                operation.eta = nil
            }
            applyFlashResult(flashed, request: request)
            let verified = flashed.verified ? " (verified)" : ""
            event = HistoryEvent(driveID: request.driveID, driveName: request.driveName,
                                 entryID: request.entryID, channelID: request.channelID,
                                 fileName: flashed.fileName, version: flashed.version,
                                 outcome: .succeeded,
                                 message: "Flashed \(request.title) \(flashed.version.raw) to “\(request.deviceName)”\(verified)")
            // PRD F23: offer the eject now that nothing is in flight.
            flashEjectOffers.insert(request.driveID)
        case .failure(let error):
            let cancelled = error == .cancelled
            mutateFlashOperation(id: request.id) { operation in
                operation.phase = cancelled ? .cancelled
                    : .failed(error.errorDescription ?? "The flash failed.")
                operation.finishedAt = Date()
            }
            if error.leavesDeviceUndefined {
                markFlashFailure(driveID: request.driveID,
                                 reason: error.errorDescription ?? "the flash did not finish")
            }
            event = HistoryEvent(driveID: request.driveID, driveName: request.driveName,
                                 entryID: request.entryID, channelID: request.channelID,
                                 fileName: DownloadArtifact.placedFileName(for: request.release)
                                     ?? request.release.fileName,
                                 version: request.release.version,
                                 outcome: cancelled ? .cancelled : .failed,
                                 message: error.errorDescription)
        }
        appendHistory(event)
        releaseFlashInFlight(driveID: request.driveID)
        notifyFlashCompletion(request: request, result: result)
    }

    /// PRD F27/F29: the fresh volume UUID is recorded for display, the
    /// assignment is marked installed, and any previous failure state clears.
    private func applyFlashResult(_ flashed: FlashedImage, request: FlashRequest) {
        guard var drive = drive(id: request.driveID),
              let index = drive.assignments.firstIndex(where: { $0.id == request.assignmentID })
        else { return }
        drive.assignments[index].installed = InstalledISO(fileName: flashed.fileName,
                                                          version: flashed.version,
                                                          placedByApp: true,
                                                          updatedAt: Date())
        if let uuid = flashed.volumeUUID { drive.volumeUUID = uuid }
        drive.lastBSDName = request.bsdName
        drive.lastSeenAt = Date()
        drive.flashFailure = nil
        updateDrive(drive)
    }

    /// DESIGN §9: a half-written stick stays flagged until a flash succeeds.
    func markFlashFailure(driveID: UUID, reason: String) {
        guard var drive = drive(id: driveID), drive.isFlashed else { return }
        drive.flashFailure = FlashFailure(reason: reason)
        updateDrive(drive)
    }

    func clearFlashEjectOffer(driveID: UUID) { flashEjectOffers.remove(driveID) }

    /// PRD F23 for flashed drives: `diskutil eject`, since there may be no
    /// mounted volume to unmount at all.
    func ejectFlashedDrive(driveID: UUID) {
        guard let drive = drive(id: driveID), !hasOperationsInFlight(drive),
              let device = attachedDevice(for: drive) else { return }
        flashEjectOffers.remove(driveID)
        Task.detached { try? DiskUtil.run(["eject", "/dev/\(device.bsdName)"]) }
    }

    private func releaseFlashInFlight(driveID: UUID) {
        let stillBusy = operations.contains { $0.driveID == driveID && $0.isActive }
        if !stillBusy { drivesWithOperationsInFlight.remove(driveID) }
    }

    private func notifyFlashCompletion(request: FlashRequest, result: FlashOutcome) {
        guard settings.notificationsEnabled, !NSApplication.shared.isActive else { return }
        let service = notifications
        switch result {
        case .success:
            Task { await service.postOperationFinished(title: request.title,
                                                       driveName: request.driveName,
                                                       succeeded: true, message: nil) }
        case .failure(let error):
            guard error != .cancelled else { return }
            Task { await service.postOperationFinished(title: request.title,
                                                       driveName: request.driveName,
                                                       succeeded: false,
                                                       message: error.errorDescription) }
        }
    }

    private func mutateFlashOperation(id: UUID, _ body: (inout UpdateOperationState) -> Void) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        body(&operations[index])
    }
}
