import AppKit
import Foundation
import IsotopeCore

// MARK: - Operation state

/// One in-flight (or just-finished) update, as the Activity view sees it
/// (DESIGN §5, PRD F24).
struct UpdateOperationState: Identifiable, Hashable, Sendable {
    enum Phase: Hashable, Sendable {
        case queued
        case downloading
        case verifying
        case extracting
        case copying
        /// PRD §8: writing the image to a raw device.
        case flashing
        /// PRD §8: reading the device back to compare hashes.
        case verifyingDevice
        case finishing
        case completed
        case failed(String)
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .completed, .failed, .cancelled: return true
            default: return false
            }
        }

        var label: String {
            switch self {
            case .queued: return "Queued"
            case .downloading: return "Downloading"
            case .verifying: return "Verifying"
            case .extracting: return "Unpacking"
            case .copying: return "Copying to drive"
            case .flashing: return "Writing to device"
            case .verifyingDevice: return "Verifying device"
            case .finishing: return "Finishing"
            case .completed: return "Done"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            }
        }
    }

    let id: UUID
    var driveID: UUID
    var driveName: String
    var assignmentID: UUID
    var entryID: String
    var channelID: String
    /// "Ubuntu Desktop — LTS"
    var title: String
    var fileName: String
    var version: String
    var phase: Phase = .queued
    var isPaused = false
    var completedBytes: Int64 = 0
    var totalBytes: Int64?
    var bytesPerSecond: Double?
    var eta: TimeInterval?
    var startedAt = Date()
    var finishedAt: Date?
    /// Set once the download is identified, so pause/cancel can reach it.
    var cacheKey: String?

    var fractionCompleted: Double? {
        if phase == .completed { return 1 }
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    var isActive: Bool { !phase.isTerminal }

    /// Only a download can be paused; a copy is short and local.
    var canPause: Bool { phase == .downloading && cacheKey != nil }

    var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }
}

enum UpdateOutcome: Sendable {
    case success(PlacedISO)
    case failure(UpdateError)
}

// MARK: - Confirmation plan (PRD F17/F21)

/// What the confirmation dialog spells out before anything is downloaded.
struct UpdatePlanItem: Identifiable, Sendable {
    var id: UUID              // assignment id
    var driveID: UUID
    var driveName: String
    var entryID: String
    var channelID: String
    var title: String
    var fromVersion: String?
    var toVersion: String
    var fileName: String
    var sizeBytes: Int64?
    /// PRD F21: false → the confirmation labels this download **unverified**.
    var isVerifiable: Bool
    /// The ISO that will be deleted, when the drive replaces rather than keeps.
    var replacesFileName: String?
    /// PRD §5.4: Windows cannot be fetched automatically.
    var needsManualDownload: Bool
    var release: Release
    /// What is on the drive for this assignment right now, whatever the drive's
    /// keep-old-versions setting says will happen to it.
    var installedFileName: String?
    /// PRD F6: the drive already keeps every old ISO, so there is nothing for
    /// F35 to rescue.
    var driveKeepsOldVersions: Bool
    /// PRD F35: the user ticked "Keep current version on the drive as a pinned
    /// copy" for this item, so the old ISO stays and becomes a `keepAsIs`
    /// assignment of its own.
    var keepReplacedAsPinned = false
    /// PRD F46 amendment: release and media revision already match, and only the
    /// servicing build differs. The download is still allowed — it is the user's
    /// call — but the sheet says plainly that Microsoft's page will most likely
    /// hand back the same media, because newer builds ship through Windows
    /// Update rather than in the ISO.
    var isBuildOnlyDifference = false

    /// PRD F35: the checkbox is offered only when an old file would actually be
    /// deleted — something is installed, it is not the file we are about to
    /// write, the drive replaces rather than keeps, and Isotope is doing the
    /// placing itself.
    var canKeepReplacedAsPinned: Bool {
        guard !needsManualDownload, !driveKeepsOldVersions else { return false }
        guard let installedFileName, installedFileName != fileName else { return false }
        return true
    }
}

struct UpdatePlan: Sendable, Identifiable {
    var id = UUID()
    var items: [UpdatePlanItem]
    var driveName: String

    var totalBytes: Int64? {
        let known = items.compactMap(\.sizeBytes)
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    var automatableItems: [UpdatePlanItem] { items.filter { !$0.needsManualDownload } }
    var manualItems: [UpdatePlanItem] { items.filter(\.needsManualDownload) }
    var hasUnverified: Bool { automatableItems.contains { !$0.isVerifiable } }
    var isEmpty: Bool { items.isEmpty }
}

// MARK: - Store surface

extension AppStore {
    // MARK: Plans

    /// Builds the confirmation plan for a set of assignments on one drive.
    func updatePlan(driveID: UUID, assignmentIDs: [UUID]) -> UpdatePlan {
        guard let drive = drive(id: driveID) else {
            return UpdatePlan(items: [], driveName: "")
        }
        let wanted = Set(assignmentIDs)
        // PRD F33: a pinned assignment's file is never touched, whoever asks.
        let items = drive.assignments.filter {
            wanted.contains($0.id) && !$0.isPinned
        }.compactMap { assignment -> UpdatePlanItem? in
            guard let release = release(for: assignment) else { return nil }
            let entry = entry(id: assignment.entryID)
            let channel = entry?.channel(id: assignment.channelID)
            let manual = channel?.provider.mechanism == .windowsManual
                || DownloadArtifact.placedFileName(for: release) == nil
            let installed = assignment.installed
            return UpdatePlanItem(
                id: assignment.id,
                driveID: drive.id,
                driveName: drive.displayName,
                entryID: assignment.entryID,
                channelID: assignment.channelID,
                title: title(for: assignment),
                fromVersion: installed?.displayVersion,
                toVersion: release.displayVersion,
                fileName: DownloadArtifact.placedFileName(for: release) ?? release.fileName,
                sizeBytes: release.sizeBytes,
                isVerifiable: release.isVerifiable,
                replacesFileName: drive.keepOldVersions ? nil : installed?.fileName,
                needsManualDownload: manual,
                release: release,
                installedFileName: installed?.fileName,
                driveKeepsOldVersions: drive.keepOldVersions,
                isBuildOnlyDifference: staleness(of: assignment, on: drive) == .buildBehind)
        }
        return UpdatePlan(items: items, driveName: drive.displayName)
    }

    /// PRD F17 "Update all": every stale assignment on the drive.
    func updatePlanForAllStale(driveID: UUID) -> UpdatePlan {
        guard let drive = drive(id: driveID) else { return UpdatePlan(items: [], driveName: "") }
        return updatePlan(driveID: driveID, assignmentIDs: staleAssignments(on: drive).map(\.id))
    }

    func title(for assignment: Assignment) -> String {
        let entry = entry(id: assignment.entryID)
        let name = entry?.name ?? assignment.entryID
        guard let channel = entry?.channel(id: assignment.channelID),
              (entry?.channels.count ?? 0) > 1 else { return name }
        return "\(name) — \(channel.name)"
    }

    // MARK: Starting work

    /// Confirmed by the user → hand the batch to the engine (DESIGN §4.5).
    func startUpdates(_ plan: UpdatePlan) {
        let requests = plan.automatableItems.map { item in
            UpdateRequest(driveID: item.driveID, driveName: item.driveName,
                          assignmentID: item.id, entryID: item.entryID,
                          channelID: item.channelID, title: item.title, release: item.release,
                          keepReplacedAsPinned: item.keepReplacedAsPinned)
        }
        guard !requests.isEmpty, let engine = updateEngine else { return }
        Task { await engine.enqueue(requests) }
    }

    /// PRD §5.4: the user fetched a Windows ISO by hand; place it with the
    /// normal pre-flight/copy/rename pipeline.
    func placeManualISO(_ found: FoundISO, for item: UpdatePlanItem) {
        guard let engine = updateEngine else { return }
        let request = UpdateRequest(driveID: item.driveID, driveName: item.driveName,
                                    assignmentID: item.id, entryID: item.entryID,
                                    channelID: item.channelID, title: item.title,
                                    release: item.release)
        Task { await engine.enqueueManual(request, sourceFile: found.url, fileName: found.fileName) }
    }

    /// The vendor page a manual entry sends the user to.
    func manualDownloadPage(entryID: String, channelID: String) -> URL? {
        guard let provider = entry(id: entryID)?.channel(id: channelID)?.provider else { return nil }
        if case .windowsManual(_, let downloadPage, _, _, _, _, _) = provider { return downloadPage }
        return entry(id: entryID)?.homepage
    }

    /// PRD F41: the regex that recognises a channel's media by filename — the
    /// same one drive scans match with. The Downloads watch uses it too, so
    /// "what this ISO is called" is defined in exactly one place: the catalog.
    func mediaFileNamePattern(entryID: String, channelID: String) -> String? {
        guard let pattern = entry(id: entryID)?.channel(id: channelID)?.provider.fileNamePattern,
              !pattern.isEmpty else { return nil }
        return pattern
    }

    /// PRD F48/F49: the download-connector configuration for a Windows channel.
    func windowsMediaCatalog(entryID: String, channelID: String) -> WindowsMediaCatalog? {
        guard let provider = entry(id: entryID)?.channel(id: channelID)?.provider,
              case .windowsManual(_, _, _, _, _, _, let catalog) = provider else { return nil }
        return catalog
    }

    /// PRD F49: try to resolve a real download link for a Windows item.
    ///
    /// Reports *what happened* rather than just failing quietly — Microsoft
    /// refusing, an entry with no connector configuration and a dead network are
    /// three different things, and the sheet says which. The caller falls back
    /// to the browser hand-off for all of them.
    func attemptWindowsDownload(for item: UpdatePlanItem) async -> WindowsDownloadAttempt {
        await attemptWindowsDownload(entryID: item.entryID, channelID: item.channelID)
    }

    /// The same attempt addressed by channel, which is what Settings' "Test"
    /// button uses: it answers "is this working?" without needing a drive, an
    /// assignment or a pending update.
    func attemptWindowsDownload(entryID: String, channelID: String) async -> WindowsDownloadAttempt {
        guard let catalog = windowsMediaCatalog(entryID: entryID, channelID: channelID),
              let referer = manualDownloadPage(entryID: entryID, channelID: channelID)
        else { return .failed("This entry has no Microsoft download configuration to try.") }
        return await windowsResolver.attempt(catalog: catalog, referer: referer)
    }

    /// The first Windows channel in the catalog, for a test that is about the
    /// mechanism rather than about one particular entry.
    var firstWindowsChannel: (entryID: String, channelID: String)? {
        for entry in allEntries where entry.kind == .windows {
            for channel in entry.channels
            where windowsMediaCatalog(entryID: entry.id, channelID: channel.id) != nil {
                return (entry.id, channel.id)
            }
        }
        return nil
    }

    /// PRD F49: hand a resolved Windows link to the ordinary pipeline —
    /// download, verify against the checksum Microsoft returned with it, place.
    /// From here on nothing about it is special-cased.
    func startResolvedWindowsDownload(_ resolved: WindowsResolvedDownload, for item: UpdatePlanItem) {
        guard let engine = updateEngine else { return }
        var release = item.release
        release.isoURL = resolved.url
        release.fileName = resolved.fileName
        release.sha256 = resolved.sha256
        let request = UpdateRequest(driveID: item.driveID, driveName: item.driveName,
                                    assignmentID: item.id, entryID: item.entryID,
                                    channelID: item.channelID, title: item.title,
                                    release: release,
                                    keepReplacedAsPinned: item.keepReplacedAsPinned)
        Task { await engine.enqueue([request]) }
    }

    func cancelOperation(id: UUID) {
        guard let engine = updateEngine else { return }
        Task { await engine.cancel(operationID: id) }
    }

    func pauseOperation(id: UUID) {
        guard let engine = updateEngine else { return }
        Task { await engine.pause(operationID: id) }
    }

    func resumeOperation(id: UUID) {
        guard let engine = updateEngine else { return }
        Task { await engine.resume(operationID: id) }
    }

    func clearFinishedOperations() {
        operations.removeAll { !$0.isActive }
    }

    // MARK: Resume offers (PRD F19)

    /// Resumable only if we still know what the download was *for*: the drive,
    /// the assignment and a current release all have to survive.
    func canResumeInterruptedDownload(_ download: InterruptedDownload) -> Bool {
        resumeRequest(for: download) != nil
    }

    func resumeInterruptedDownload(_ download: InterruptedDownload) {
        guard let request = resumeRequest(for: download), let engine = updateEngine else { return }
        interruptedDownloads.removeAll { $0.id == download.id }
        Task { await engine.enqueue([request]) }
    }

    func discardInterruptedDownload(_ download: InterruptedDownload) {
        interruptedDownloads.removeAll { $0.id == download.id }
        guard let downloads = downloadManager else { return }
        Task { await downloads.discardResumable(key: download.id) }
    }

    private func resumeRequest(for download: InterruptedDownload) -> UpdateRequest? {
        guard let driveID = download.driveID, let assignmentID = download.assignmentID,
              let drive = drive(id: driveID),
              let assignment = drive.assignments.first(where: { $0.id == assignmentID }),
              let release = release(for: assignment) else { return nil }
        return UpdateRequest(driveID: driveID, driveName: drive.displayName,
                             assignmentID: assignmentID, entryID: assignment.entryID,
                             channelID: assignment.channelID,
                             title: title(for: assignment), release: release)
    }

    // MARK: Engine callbacks

    func updateSnapshot(driveID: UUID, assignmentID: UUID) -> DriveUpdateSnapshot? {
        guard let drive = drive(id: driveID) else { return nil }
        let assignment = drive.assignments.first { $0.id == assignmentID }
        return DriveUpdateSnapshot(driveID: drive.id,
                                   driveName: drive.displayName,
                                   bookmark: drive.bookmark,
                                   isoFolder: drive.isoFolder,
                                   keepOldVersions: drive.keepOldVersions,
                                   installedFileName: assignment?.installed?.fileName,
                                   isConnected: isConnected(drive))
    }

    /// A stale bookmark still works but should be rewritten (DESIGN §4.5 step 1).
    func refreshBookmark(_ bookmark: Data, for driveID: UUID) {
        guard var drive = drive(id: driveID), drive.bookmark != bookmark else { return }
        drive.bookmark = bookmark
        updateDrive(drive)
    }

    func beginOperation(for request: UpdateRequest) {
        let state = UpdateOperationState(
            id: request.id, driveID: request.driveID, driveName: request.driveName,
            assignmentID: request.assignmentID, entryID: request.entryID,
            channelID: request.channelID, title: request.title,
            fileName: DownloadArtifact.placedFileName(for: request.release) ?? request.release.fileName,
            version: request.release.version.raw,
            totalBytes: request.release.sizeBytes)
        operations.removeAll { $0.id == request.id }
        operations.append(state)
        // PRD F23: Eject and Unregister stay disabled while this runs.
        drivesWithOperationsInFlight.insert(request.driveID)
    }

    func setOperationCacheKey(id: UUID, key: String) {
        mutateOperation(id: id) { $0.cacheKey = key }
    }

    func updateOperationProgress(id: UUID, stage: DownloadStage?, progress: TransferProgress) {
        mutateOperation(id: id) { operation in
            if let stage {
                switch stage {
                case .cached, .downloading: operation.phase = .downloading
                case .verifying: operation.phase = .verifying
                case .extracting: operation.phase = .extracting
                }
            }
            operation.completedBytes = progress.completedBytes
            if let total = progress.totalBytes, total > 0 { operation.totalBytes = total }
            operation.bytesPerSecond = progress.bytesPerSecond
            operation.eta = progress.eta
        }
    }

    func updateOperationPhase(id: UUID, phase: UpdateOperationState.Phase, totalBytes: Int64?) {
        mutateOperation(id: id) { operation in
            operation.phase = phase
            operation.completedBytes = 0
            if let totalBytes { operation.totalBytes = totalBytes }
            operation.bytesPerSecond = nil
            operation.eta = nil
        }
    }

    func markOperationPaused(id: UUID, paused: Bool) {
        mutateOperation(id: id) { $0.isPaused = paused }
    }

    /// Terminal step: write the assignment back, log history, release the
    /// in-flight flag, notify (DESIGN §4.5 step 6).
    func finishOperation(request: UpdateRequest, result: UpdateOutcome) {
        var event: HistoryEvent
        switch result {
        case .success(let placed):
            mutateOperation(id: request.id) { operation in
                operation.phase = .completed
                operation.finishedAt = Date()
                operation.completedBytes = placed.sizeBytes
                operation.totalBytes = placed.sizeBytes
                operation.bytesPerSecond = nil
                operation.eta = nil
            }
            applyPlacement(placed, request: request)
            let replaced = placed.removedFileName.map { " (replaced \($0))" } ?? ""
            // PRD F47: say so when the download was deleted again, so the
            // reclaimed space is visible rather than mysterious.
            let reclaimed = placed.reclaimedCacheBytes > 0
                ? " · freed \(ByteCountFormatter.string(fromByteCount: placed.reclaimedCacheBytes, countStyle: .file)) of cache"
                : ""
            // PRD F64: moving someone's own download is worth saying out loud,
            // including where it went.
            let trashed = placed.trashedSourceName.map { " · moved “\($0)” to the Trash" } ?? ""
            event = HistoryEvent(driveID: request.driveID, driveName: request.driveName,
                                 entryID: request.entryID, channelID: request.channelID,
                                 fileName: placed.fileName, version: placed.version,
                                 outcome: .succeeded,
                                 message: "\(request.title) \(placed.version.raw)\(replaced)\(reclaimed)\(trashed)")
        case .failure(let error):
            let cancelled = error == .cancelled
            mutateOperation(id: request.id) { operation in
                operation.phase = cancelled ? .cancelled
                    : .failed(error.errorDescription ?? "The update failed.")
                operation.finishedAt = Date()
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
        releaseInFlight(driveID: request.driveID)
        notifyCompletion(request: request, result: result)
    }

    private func applyPlacement(_ placed: PlacedISO, request: UpdateRequest) {
        guard var drive = drive(id: request.driveID),
              let index = drive.assignments.firstIndex(where: { $0.id == request.assignmentID })
        else { return }
        let previous = drive.assignments[index].installed
        drive.assignments[index].installed = InstalledISO(fileName: placed.fileName,
                                                          version: placed.version,
                                                          placedByApp: true,
                                                          updatedAt: Date())
        // PRD F35: the old ISO was deliberately left on the drive, so it becomes
        // a pinned assignment of its own rather than an untracked stray file.
        // Never on a flashed drive — one image per device is unchanged (F26/F37).
        if let retained = placed.retainedFileName, !drive.isFlashed,
           let carried = previous, carried.fileName == retained {
            drive.assignments.insert(Assignment(entryID: request.entryID,
                                                channelID: request.channelID,
                                                installed: carried,
                                                updatePolicy: .keepAsIs),
                                     at: index + 1)
        }
        updateDrive(drive)
        // PRD F43 addendum: a freshly placed Windows ISO is the one case where
        // the file that just landed still has not said which build it is.
        refreshWindowsBuilds(driveID: request.driveID)
        // The replaced file is no longer on the drive, so drop it from the
        // informational "other ISOs" list if it was ever listed there.
        if let removed = placed.removedFileName {
            unknownISOFiles[request.driveID]?.removeAll { $0 == removed }
            refreshDetectedISOs(driveID: request.driveID)
        }
    }

    private func releaseInFlight(driveID: UUID) {
        let stillBusy = operations.contains { $0.driveID == driveID && $0.isActive }
        if !stillBusy { drivesWithOperationsInFlight.remove(driveID) }
    }

    private func notifyCompletion(request: UpdateRequest, result: UpdateOutcome) {
        // Only when the user is not looking at the app (DESIGN §4.6), and only
        // when notifications are switched on in Settings.
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

    private func mutateOperation(id: UUID, _ body: (inout UpdateOperationState) -> Void) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        body(&operations[index])
    }

    // MARK: Drive-connect notification (PRD F16)

    /// Called by `DriveMonitor` *after* the targeted catalog check, so the
    /// summary reflects post-check staleness rather than a stale cache.
    func announceUpdates(for driveID: UUID) {
        guard let drive = drive(id: driveID) else { return }
        let stale = staleAssignments(on: drive)
        guard !stale.isEmpty else {
            lastAnnouncedUpdates[driveID] = nil
            return
        }
        let summaries = stale.map { assignment -> String in
            let version = release(for: assignment)?.version.raw
            let name = entry(id: assignment.entryID)?.name ?? assignment.entryID
            return version.map { "\(name) \($0)" } ?? name
        }
        // One notice per drive per set of updates: replugging the same stick
        // five times must not produce five identical banners.
        guard lastAnnouncedUpdates[driveID] != summaries else { return }
        lastAnnouncedUpdates[driveID] = summaries
        guard settings.notificationsEnabled else { return }
        let service = notifications
        let name = drive.displayName
        Task { await service.postDriveUpdates(driveID: driveID, driveName: name, summaries: summaries) }
    }

    // MARK: History from scans (Phase 3 left this open)

    /// PRD F7/F24: a tracked ISO that vanished between scans is worth logging —
    /// the user deleted it, or a copy failed on another machine.
    func recordReconcileHistory(_ result: ReconcileResult, driveID: UUID) {
        guard let drive = drive(id: driveID) else { return }
        for outcome in result.changes where outcome.change == .missing {
            guard let previous = outcome.previousFileName,
                  let assignment = drive.assignments.first(where: { $0.id == outcome.assignmentID })
            else { continue }
            appendHistory(HistoryEvent(date: result.scannedAt,
                                        driveID: driveID, driveName: drive.displayName,
                                        entryID: assignment.entryID, channelID: assignment.channelID,
                                        fileName: previous, version: assignment.installed?.version,
                                        outcome: .failed,
                                        message: "“\(previous)” is no longer on the drive."))
        }
    }
}
