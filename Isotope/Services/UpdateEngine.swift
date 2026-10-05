import Foundation
import IsotopeCore

// MARK: - Errors (PRD F25: every failure is actionable)

enum UpdateError: LocalizedError, Equatable {
    case driveNotConnected(String)
    case driveReadOnly(String)
    case bookmarkUnresolvable(String)
    case noDownloadURL(entryName: String)
    case windowsManual(entryName: String)
    case insufficientSpace(shortfallBytes: Int64, driveName: String)
    case checksumMismatch(fileName: String)
    case downloadFailed(String)
    case extractionFailed(String)
    case copyFailed(String)
    case driveVanished(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .driveNotConnected(let name):
            return "“\(name)” is not connected. Plug the drive in and try again."
        case .driveReadOnly(let name):
            return "“\(name)” is mounted read-only, so Isotope cannot write to it. Check the drive's write-protect switch, or remount it."
        case .bookmarkUnresolvable(let name):
            return "Isotope lost its permission to write to “\(name)”. Unregister the drive and register it again — nothing on it is changed."
        case .noDownloadURL(let entryName):
            return "The latest release of \(entryName) does not publish a direct ISO link, so Isotope cannot download it automatically."
        case .windowsManual(let entryName):
            return "\(entryName) has to be downloaded from Microsoft by hand — its links are session-generated and expire. Use “Get Windows ISO…” to start."
        case .insufficientSpace(let shortfall, let driveName):
            let needed = ByteCountFormatter.string(fromByteCount: shortfall, countStyle: .file)
            return "“\(driveName)” does not have room for this ISO — it is \(needed) short, even after removing the version being replaced. Free up space and try again."
        case .checksumMismatch(let fileName):
            return "Checksum mismatch on “\(fileName)” — the download was corrupted or the source's checksum file is stale. The file was discarded; try again."
        case .downloadFailed(let message):
            return message
        case .extractionFailed(let message):
            return message
        case .copyFailed(let message):
            return "The copy to the drive failed: \(message)"
        case .driveVanished(let name):
            return "“\(name)” was disconnected during the copy. Nothing usable was left behind — the partial file is cleaned up when the drive is reconnected."
        case .cancelled:
            return "The update was cancelled."
        }
    }
}

// MARK: - Requests & snapshots

/// One confirmed assignment to bring up to date (DESIGN §4.5).
struct UpdateRequest: Sendable, Identifiable {
    var id: UUID = UUID()          // also the operation id
    var driveID: UUID
    var driveName: String
    var assignmentID: UUID
    var entryID: String
    var channelID: String
    /// "Ubuntu Desktop — LTS", for the UI and history.
    var title: String
    var release: Release
    /// PRD F35: the confirmation offered to keep the ISO being replaced, and the
    /// user took it — the old file is not deleted, and the store turns it into a
    /// pinned assignment afterwards.
    var keepReplacedAsPinned = false
}

/// Everything the engine needs off the main actor in one read, so drive state
/// cannot change shape underneath a long copy.
struct DriveUpdateSnapshot: Sendable {
    var driveID: UUID
    var driveName: String
    var bookmark: Data
    var isoFolder: String
    var keepOldVersions: Bool
    var installedFileName: String?
    var isConnected: Bool
}

/// The result of a successful operation, written back to the assignment.
struct PlacedISO: Sendable {
    var fileName: String
    var version: VersionToken
    var removedFileName: String?
    var sizeBytes: Int64
    /// PRD F35: the old ISO that was kept instead of deleted, for the store to
    /// turn into a pinned assignment.
    var retainedFileName: String?
    /// PRD F47: cache bytes freed by deleting the download once it was placed.
    /// Zero when the setting is off, or when something else still needs the file.
    var reclaimedCacheBytes: Int64 = 0
    /// PRD F64: the hand-downloaded file moved to the Trash after placing it.
    var trashedSourceName: String?
}

// MARK: - Engine

/// DESIGN §4.5. Operations for one drive run strictly in order (a single USB
/// stick has one write head and one free-space budget); different drives
/// interleave, and their downloads are shared by `DownloadManager` (PRD F20).
actor UpdateEngine {
    private let store: AppStore
    private let downloads: ISOProviding
    private let drives: DriveWriting

    /// One serial chain per drive; new work is appended to its predecessor.
    private var chains: [UUID: Task<Void, Never>] = [:]
    private var cancellations: [UUID: CancellationFlag] = [:]
    private var cacheKeys: [UUID: String] = [:]
    /// Queued behind another operation on the same drive and not started yet.
    /// Cancelling one of these ends it on the spot instead of when its turn
    /// would have come.
    private var waiting: [UUID: UpdateRequest] = [:]
    /// PRD F47: cache keys the queue still has work for, counted. A placed ISO
    /// is deleted straight away — but not while a *later* item in the same
    /// batch is going to want the identical file, which is exactly what
    /// "Update All" across two sticks holding the same distro produces.
    private var queuedCacheKeys: [String: Int] = [:]
    /// Requests that have already given up their claim on a cache key, so the
    /// bookkeeping stays right whether the operation ended in a placement or a
    /// failure.
    private var releasedRequests: Set<UUID> = []

    var copyChunkSize = ChunkedCopy.defaultChunkSize

    init(store: AppStore, downloads: ISOProviding, drives: DriveWriting = LiveDriveWriter()) {
        self.store = store
        self.downloads = downloads
        self.drives = drives
    }

    func setCopyChunkSize(_ size: Int) { copyChunkSize = max(4096, size) }

    // MARK: Queueing

    /// PRD F17: called only after the user confirmed. "Update All" passes the
    /// whole batch at once.
    func enqueue(_ requests: [UpdateRequest]) async {
        // PRD F47: every claim on a cached ISO is registered before any work
        // starts. Counting them as each operation is queued would let the first
        // one finish — `beginOperation` suspends — while the second is still
        // uncounted, and delete the file that second one was about to copy.
        for request in requests where Self.cacheKey(for: request) != nil {
            queuedCacheKeys[Self.cacheKey(for: request)!, default: 0] += 1
        }
        for request in requests {
            cancellations[request.id] = CancellationFlag()
            waiting[request.id] = request
            await store.beginOperation(for: request)
            let previous = chains[request.driveID]
            chains[request.driveID] = Task { [weak self] in
                _ = await previous?.result
                await self?.perform(request)
            }
        }
    }

    /// PRD §5.4 Windows flow: place a file the user downloaded themselves.
    func enqueueManual(_ request: UpdateRequest, sourceFile: URL, fileName: String) async {
        cancellations[request.id] = CancellationFlag()
        waiting[request.id] = request
        await store.beginOperation(for: request)
        let previous = chains[request.driveID]
        chains[request.driveID] = Task { [weak self] in
            _ = await previous?.result
            guard let self else { return }
            await self.performManual(request, sourceFile: sourceFile, fileName: fileName)
        }
    }

    private func performManual(_ request: UpdateRequest, sourceFile: URL, fileName: String) async {
        defer { cancellations[request.id] = nil }
        // Already finished by `cancel` while it was queued.
        guard waiting.removeValue(forKey: request.id) != nil else { return }
        do {
            let placed = try await executeManual(request, sourceFile: sourceFile, fileName: fileName)
            await store.finishOperation(request: request, result: .success(placed))
        } catch let error as UpdateError {
            await store.finishOperation(request: request, result: .failure(error))
        } catch {
            await store.finishOperation(request: request,
                                        result: .failure(.copyFailed(error.localizedDescription)))
        }
    }

    /// Waits for every queued operation to finish — used by tests and by a
    /// clean quit.
    func drain() async {
        let running = chains.values
        for chain in running { _ = await chain.result }
    }

    func cancel(operationID: UUID) async {
        guard let flag = cancellations[operationID] else { return }
        flag.set()
        if let request = waiting.removeValue(forKey: operationID) {
            // Nothing has started, so there is nothing to wind down. Its chain
            // task still runs when its turn comes, finds it gone and returns.
            await store.finishOperation(request: request, result: .failure(.cancelled))
            return
        }
        if let key = cacheKeys[operationID] { await downloads.cancel(cacheKey: key) }
    }

    func pause(operationID: UUID) async {
        guard let key = cacheKeys[operationID] else { return }
        await downloads.pause(cacheKey: key)
        await store.markOperationPaused(id: operationID, paused: true)
    }

    func resume(operationID: UUID) async {
        guard let key = cacheKeys[operationID] else { return }
        await downloads.resume(cacheKey: key)
        await store.markOperationPaused(id: operationID, paused: false)
    }

    // MARK: One operation

    private func perform(_ request: UpdateRequest) async {
        defer {
            cancellations[request.id] = nil
            cacheKeys[request.id] = nil
            // Safety net: an operation that never reached the placement still
            // has to stop counting against the ISO it was going to want.
            releaseClaim(of: request)
            releasedRequests.remove(request.id)
        }
        // Already finished by `cancel` while it was queued.
        guard waiting.removeValue(forKey: request.id) != nil else { return }
        if cancellations[request.id]?.isSet == true {
            await store.finishOperation(request: request, result: .failure(.cancelled))
            return
        }
        do {
            let placed = try await execute(request)
            await store.finishOperation(request: request, result: .success(placed))
        } catch let error as UpdateError {
            await store.finishOperation(request: request, result: .failure(error))
        } catch let error as DownloadError {
            await store.finishOperation(request: request, result: .failure(Self.map(error)))
        } catch is CancellationError {
            await store.finishOperation(request: request, result: .failure(.cancelled))
        } catch {
            await store.finishOperation(request: request,
                                        result: .failure(.copyFailed(error.localizedDescription)))
        }
    }

    private static func map(_ error: DownloadError) -> UpdateError {
        switch error {
        case .checksumMismatch(let fileName): return .checksumMismatch(fileName: fileName)
        case .cancelled: return .cancelled
        case .transport, .sizeMismatch, .httpStatus: return .downloadFailed(error.localizedDescription)
        }
    }

    /// Steps 1–2 of DESIGN §4.5, shared by the automatic and the manual
    /// (Windows) paths: resolve the bookmark, take security scope, refuse a
    /// read-only mount.
    private func openDrive(_ request: UpdateRequest) async throws
        -> (snapshot: DriveUpdateSnapshot, volume: URL, scoped: Bool) {
        guard let snapshot = await store.updateSnapshot(driveID: request.driveID,
                                                        assignmentID: request.assignmentID)
        else { throw UpdateError.driveNotConnected(request.driveName) }
        guard snapshot.isConnected else { throw UpdateError.driveNotConnected(snapshot.driveName) }

        let resolved: ResolvedVolume
        do {
            resolved = try drives.resolveVolume(bookmark: snapshot.bookmark)
        } catch {
            throw UpdateError.bookmarkUnresolvable(snapshot.driveName)
        }
        if let refreshed = resolved.refreshedBookmark {
            await store.refreshBookmark(refreshed, for: snapshot.driveID)
        }
        let scoped = drives.beginAccess(resolved.url)
        if (try? drives.volumeInfo(at: resolved.url))?.isReadOnly == true {
            if scoped { drives.endAccess(resolved.url) }
            throw UpdateError.driveReadOnly(snapshot.driveName)
        }
        return (snapshot, resolved.url, scoped)
    }

    private func execute(_ request: UpdateRequest) async throws -> PlacedISO {
        let (snapshot, volume, scoped) = try await openDrive(request)
        defer { if scoped { drives.endAccess(volume) } }

        // 2 — what we are placing.
        guard request.release.isoURL != nil,
              let finalName = DownloadArtifact.placedFileName(for: request.release)
        else { throw UpdateError.noDownloadURL(entryName: request.title) }
        let sourceURL = request.release.isoURL!
        let publishedName = request.release.fileName.isEmpty
            ? sourceURL.lastPathComponent : request.release.fileName

        // 3 — ensure the ISO is in the local cache (download + verify + unzip).
        let isoRequest = ISORequest(
            sourceURL: sourceURL, fileName: publishedName, sha256: request.release.sha256,
            expectedSizeBytes: request.release.sizeBytes,
            context: DownloadContext(driveID: snapshot.driveID, driveName: snapshot.driveName,
                                     entryID: request.entryID, channelID: request.channelID,
                                     assignmentID: request.assignmentID))
        cacheKeys[request.id] = isoRequest.cacheKey
        await store.setOperationCacheKey(id: request.id, key: isoRequest.cacheKey)
        // A cancel that landed before the cache key was known had no download
        // to stop, so it is honoured here rather than after the download.
        if cancellations[request.id]?.isSet == true { throw UpdateError.cancelled }

        let operationID = request.id
        let store = self.store
        let local: LocalISO
        do {
            local = try await downloads.ensureLocalISO(isoRequest) { stage, progress in
                Task { @MainActor in
                    store.updateOperationProgress(id: operationID, stage: stage, progress: progress)
                }
            }
        } catch let error as ArchiveExtractionError {
            throw UpdateError.extractionFailed(error.localizedDescription)
        }
        do {
            let placed = try await place(local, request: request, snapshot: snapshot,
                                         volume: volume, finalName: finalName)
            // PRD F47: it is on the drive now. Unless the user turned it off, or
            // something else still needs this exact file, the cached copy goes.
            let discard = await shouldDiscard(cacheKey: local.cacheKey, request: request)
            let freed = await downloads.endUse(cacheKey: local.cacheKey, discard: discard)
            var result = placed
            result.reclaimedCacheBytes = freed
            return result
        } catch {
            // A failed copy leaves the download cached: retrying should not mean
            // downloading four gigabytes a second time.
            await downloads.endUse(cacheKey: local.cacheKey, discard: false)
            throw error
        }
    }

    /// True when the placed ISO should be deleted from the cache now: the
    /// setting is on, and no other queued operation is waiting for the same file.
    ///
    /// This request gives up its own claim *first*, then asks whether anything
    /// is left. Deciding before releasing would let two drives copying the same
    /// ISO concurrently each see the other's claim and neither delete — the
    /// order is what makes the outcome independent of how they interleave.
    private func shouldDiscard(cacheKey: String, request: UpdateRequest) async -> Bool {
        // The setting is read *first*, before the claim is given up: awaiting the
        // main actor in between would suspend this operation mid-decision, and
        // two drives finishing the same ISO could both release, both resume, and
        // both conclude they were last. Release and check must happen in one
        // uninterrupted run of the actor.
        let wanted = await store.discardsCacheAfterPlacement
        releaseClaim(of: request)
        guard wanted, !cacheKey.isEmpty else { return false }
        return queuedCacheKeys[cacheKey] == nil
    }

    /// Drops one request's claim on its cache key. Idempotent: it runs at the
    /// end of a placement and again from `perform`'s defer, and must not
    /// double-count either way.
    private func releaseClaim(of request: UpdateRequest) {
        guard !releasedRequests.contains(request.id),
              let key = Self.cacheKey(for: request) else { return }
        releasedRequests.insert(request.id)
        if let count = queuedCacheKeys[key], count > 1 {
            queuedCacheKeys[key] = count - 1
        } else {
            queuedCacheKeys[key] = nil
        }
    }

    /// The cache key an update will use, known before it starts running.
    private static func cacheKey(for request: UpdateRequest) -> String? {
        guard let sourceURL = request.release.isoURL else { return nil }
        let published = request.release.fileName.isEmpty
            ? sourceURL.lastPathComponent : request.release.fileName
        return DownloadArtifact.cacheKey(sha256: request.release.sha256,
                                         sourceURL: sourceURL, fileName: published)
    }

    /// PRD §5.4: the user fetched the ISO themselves (Windows), so there is
    /// nothing to download — everything from the pre-flight onwards is identical.
    private func executeManual(_ request: UpdateRequest, sourceFile: URL,
                               fileName: String) async throws -> PlacedISO {
        let (snapshot, volume, scoped) = try await openDrive(request)
        defer { if scoped { drives.endAccess(volume) } }
        guard let size = Self.fileSize(sourceFile), size > 0 else {
            throw UpdateError.copyFailed("“\(fileName)” could not be read from your Downloads folder.")
        }
        let local = LocalISO(url: sourceFile, fileName: fileName, sizeBytes: size, cacheKey: "")
        var placed = try await place(local, request: request, snapshot: snapshot,
                                     volume: volume, finalName: fileName)
        // PRD F64: it is on the drive now, so the download has done its job.
        if await store.trashesManualSourceAfterPlacement,
           Self.trashSource(sourceFile, volume: volume) {
            placed.trashedSourceName = sourceFile.lastPathComponent
        }
        return placed
    }

    /// Moves a hand-downloaded ISO to the Trash once it has been placed.
    ///
    /// Two refusals, both deliberate:
    ///
    /// * anything *on the drive itself* is left alone. "Choose File…" can point
    ///   at an ISO already on the stick, and trashing that would delete the very
    ///   file just placed — or another image the user keeps there;
    /// * a failure is silent. Some volumes have no Trash, and a file that could
    ///   not be moved is not a failed update.
    static func trashSource(_ source: URL, volume: URL) -> Bool {
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        let volumePath = volume.resolvingSymlinksInPath().standardizedFileURL.path
        guard !sourcePath.hasPrefix(volumePath.hasSuffix("/") ? volumePath : volumePath + "/"),
              sourcePath != volumePath else { return false }
        return (try? FileManager.default.trashItem(at: source, resultingItemURL: nil)) != nil
    }

    /// Steps 4–6 of DESIGN §4.5: pre-flight, copy, rename, delete the old ISO.
    private func place(_ local: LocalISO, request: UpdateRequest, snapshot: DriveUpdateSnapshot,
                       volume: URL, finalName: String) async throws -> PlacedISO {
        let manager = FileManager.default
        let folder = DriveAccess.isoFolderURL(volume: volume, isoFolder: snapshot.isoFolder)
        do {
            // PRD F22: the ISO folder is the only place Isotope ever writes.
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw UpdateError.copyFailed(error.localizedDescription)
        }

        // The old ISO this update replaces — the only file we are ever allowed
        // to delete (PRD F22), and only when the drive replaces rather than keeps.
        // PRD F35: a kept-as-pinned copy is off-limits for exactly the same
        // reasons the drive-level "keep old versions" setting is — including the
        // pre-flight, which may not count its bytes as reclaimable.
        let keepsOldFile = snapshot.keepOldVersions || request.keepReplacedAsPinned
        // PRD F61. The file being replaced plays two different parts, and
        // conflating them is what made a same-named replacement impossible:
        //
        //  * its bytes are *reclaimable*, whatever it is called — deleting it
        //    before the copy frees exactly that much;
        //  * only a *differently* named one is deleted afterwards, because the
        //    rename at the end already overwrote a file sharing the new name.
        //
        // Reading the second rule into the first is what produced "8.47 GB
        // short" on a stick already holding 8.47 GB of the very file being
        // replaced.
        // What is on the drive now, whatever becomes of it. PRD F35 still needs
        // this name when the user asked to keep the outgoing file as a pin, so
        // it is deliberately *not* gated on `keepsOldFile`.
        let installedName = snapshot.installedFileName
        let oldName = installedName.flatMap { $0 == finalName ? nil : $0 }
        let oldURL = oldName.map { folder.appendingPathComponent($0) }
        // The bytes that may be freed before the copy: any name, but only when
        // the drive is replacing rather than keeping. A file the user asked to
        // keep is not Isotope's to spend.
        let replacedURL = keepsOldFile ? nil : installedName.map { folder.appendingPathComponent($0) }
        let reclaimable = replacedURL.flatMap(Self.fileSize) ?? 0

        // Free space is re-read here, not before the download: a long download
        // gives the user plenty of time to fill the stick from elsewhere.
        let available = (try? drives.volumeInfo(at: volume))?.availableBytes ?? 0
        let plan = SpacePlan(requiredBytes: local.sizeBytes, availableBytes: available,
                             reclaimableBytes: reclaimable)
        guard plan.fits else {
            throw UpdateError.insufficientSpace(shortfallBytes: plan.shortfallBytes,
                                                driveName: snapshot.driveName)
        }

        // PRD F18: when it only fits once the old file is gone, the old file
        // goes first — including when it shares the new name, which is the case
        // that used to be refused outright. The source is always the cache or
        // the user's Downloads folder, never this file, so removing it here
        // cannot take the copy's own input with it.
        var removedEarly = false
        if plan.requiresReclaimFirst, let replacedURL {
            try? manager.removeItem(at: replacedURL)
            removedEarly = true
        }

        await store.updateOperationPhase(id: request.id, phase: .copying,
                                         totalBytes: local.sizeBytes)
        let partURL = folder.appendingPathComponent(DownloadArtifact.partFileName(for: finalName))
        let flag = cancellations[request.id] ?? CancellationFlag()
        let operationID = request.id
        let store = self.store
        let chunkSize = copyChunkSize
        let source = local.url
        let total = local.sizeBytes
        let folderPath = folder.path

        do {
            let estimator = RateBox()
            let throttle = ProgressThrottle()
            try await Task.detached(priority: .userInitiated) {
                try ChunkedCopy.run(from: source, to: partURL, chunkSize: chunkSize, control: {
                    if flag.isSet { return .cancel }
                    // A pulled-out stick keeps the open descriptor alive, so the
                    // folder itself is what we poll (DESIGN §6).
                    return FileManager.default.fileExists(atPath: folderPath) ? .proceed : .driveGone
                }, progress: { written in
                    let snapshot = estimator.record(written: written, total: total)
                    // PRD F62: the rate estimator sees every chunk; the UI does
                    // not need to.
                    guard throttle.shouldEmit(force: written >= total) else { return }
                    Task { @MainActor in
                        store.updateOperationProgress(id: operationID, stage: nil, progress: snapshot)
                    }
                }, willSynchronize: {
                    // PRD F65: the last flush is part of the copy, and says so.
                    Task { @MainActor in
                        store.updateOperationPhase(id: operationID, phase: .finishing,
                                                   totalBytes: total)
                    }
                })
            }.value
        } catch let failure as ChunkedCopy.Failure {
            switch failure {
            case .cancelled: throw UpdateError.cancelled
            case .driveGone: throw UpdateError.driveVanished(snapshot.driveName)
            case .driveFull(let bytesWritten):
                // PRD F68: what it actually was, with the real figure — the
                // pre-flight's estimate was evidently optimistic, so quote the
                // shortfall the copy discovered rather than the one it predicted.
                throw UpdateError.insufficientSpace(shortfallBytes: max(0, local.sizeBytes - bytesWritten),
                                                    driveName: snapshot.driveName)
            case .io(let message): throw UpdateError.copyFailed(message)
            }
        }

        // PRD F18: verify the copied size before it is given the real name.
        let copiedBytes = Self.fileSize(partURL) ?? 0
        guard copiedBytes == local.sizeBytes else {
            try? manager.removeItem(at: partURL)
            // PRD F68: "not the same size as the source" described the symptom
            // and left the user nowhere to go. Short almost always means the
            // volume filled up — say so, with both figures.
            throw UpdateError.copyFailed(Self.shortCopyMessage(copied: copiedBytes,
                                                               expected: local.sizeBytes,
                                                               driveName: snapshot.driveName))
        }

        await store.updateOperationPhase(id: request.id, phase: .finishing, totalBytes: local.sizeBytes)
        let finalURL = folder.appendingPathComponent(finalName)
        do {
            if manager.fileExists(atPath: finalURL.path) { try manager.removeItem(at: finalURL) }
            try manager.moveItem(at: partURL, to: finalURL)
        } catch {
            try? manager.removeItem(at: partURL)
            throw UpdateError.copyFailed(error.localizedDescription)
        }

        var removedName: String?
        if let oldURL, let oldName, !keepsOldFile {
            if removedEarly {
                removedName = oldName
            } else if manager.fileExists(atPath: oldURL.path) {
                try? manager.removeItem(at: oldURL)
                removedName = oldName
            }
        }
        // Only what the user asked to pin: a drive-level "keep old versions"
        // leaves the file alone as before, untracked.
        let retainedName = request.keepReplacedAsPinned && !snapshot.keepOldVersions
            ? oldName.flatMap { manager.fileExists(atPath: folder.appendingPathComponent($0).path) ? $0 : nil }
            : nil
        return PlacedISO(fileName: finalName, version: request.release.version,
                         removedFileName: removedName, sizeBytes: local.sizeBytes,
                         retainedFileName: retainedName)
    }

    /// PRD F68: what to say when the file on the drive is not the size it
    /// should be. "Not the same size as the source" described the symptom and
    /// left the user nowhere to go; short almost always means the volume filled
    /// up, and the two figures make that obvious.
    static func shortCopyMessage(copied: Int64, expected: Int64, driveName: String) -> String {
        let landed = ByteCountFormatter.string(fromByteCount: copied, countStyle: .file)
        let wanted = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
        guard copied < expected else {
            return "The copy came out at \(landed) instead of \(wanted). It was discarded; try again."
        }
        return "Only \(landed) of the \(wanted) ISO reached “\(driveName)” — the drive filled up. The partial file was discarded; free up space and try again."
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }
}

/// Carries the copy's rate estimator across the concurrency boundary between
/// the detached copy loop and the main-actor progress updates.
private final class RateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var estimator = TransferRateEstimator()

    func record(written: Int64, total: Int64) -> TransferProgress {
        lock.lock()
        defer { lock.unlock() }
        estimator.record(totalBytes: written, at: Date())
        return TransferProgress(completedBytes: written, totalBytes: total,
                                bytesPerSecond: estimator.bytesPerSecond,
                                eta: estimator.eta(remainingBytes: total - written))
    }
}

// MARK: - Orphan cleanup (DESIGN §6)

enum PartFileCleanup {
    /// Deletes `.iso.part` leftovers from an interrupted copy. Called on drive
    /// connect; only ever touches files Isotope itself created, in the drive's
    /// configured ISO folder (PRD F22).
    @discardableResult
    static func run(volume: URL, isoFolder: String) -> [String] {
        let folder = DriveAccess.isoFolderURL(volume: volume, isoFolder: isoFolder)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var removed: [String] = []
        for name in names where DownloadArtifact.isPartFileName(name) {
            do {
                try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                removed.append(name)
            } catch {
                continue
            }
        }
        return removed
    }
}
