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
    /// PRD F47: cache keys the queue still has work for, counted. A placed ISO
    /// is deleted straight away — but not while a *later* item in the same
    /// batch is going to want the identical file, which is exactly what
    /// "Update All" across two sticks holding the same distro produces.
    private var queuedCacheKeys: [String: Int] = [:]

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
        for request in requests {
            cancellations[request.id] = CancellationFlag()
            if let key = Self.cacheKey(for: request) { queuedCacheKeys[key, default: 0] += 1 }
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
        cancellations[operationID]?.set()
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
            if let key = Self.cacheKey(for: request) { releaseQueued(key) }
        }
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
        case .transport, .sizeMismatch: return .downloadFailed(error.localizedDescription)
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
            let discard = await shouldDiscard(cacheKey: local.cacheKey)
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
    private func shouldDiscard(cacheKey: String) async -> Bool {
        guard !cacheKey.isEmpty, await store.discardsCacheAfterPlacement else { return false }
        // This operation's own entry is still counted, hence "> 1".
        return (queuedCacheKeys[cacheKey] ?? 0) <= 1
    }

    private func releaseQueued(_ key: String) {
        guard let count = queuedCacheKeys[key] else { return }
        if count <= 1 { queuedCacheKeys[key] = nil } else { queuedCacheKeys[key] = count - 1 }
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
        return try await place(local, request: request, snapshot: snapshot,
                               volume: volume, finalName: fileName)
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
        let oldName = snapshot.installedFileName.flatMap { $0 == finalName ? nil : $0 }
        let oldURL = oldName.map { folder.appendingPathComponent($0) }
        let oldSize = oldURL.flatMap(Self.fileSize) ?? 0
        let reclaimable = keepsOldFile ? 0 : oldSize

        // Free space is re-read here, not before the download: a long download
        // gives the user plenty of time to fill the stick from elsewhere.
        let available = (try? drives.volumeInfo(at: volume))?.availableBytes ?? 0
        let plan = SpacePlan(requiredBytes: local.sizeBytes, availableBytes: available,
                             reclaimableBytes: reclaimable)
        guard plan.fits else {
            throw UpdateError.insufficientSpace(shortfallBytes: plan.shortfallBytes,
                                                driveName: snapshot.driveName)
        }

        var removedEarly = false
        if plan.requiresReclaimFirst, let oldURL {
            try? manager.removeItem(at: oldURL)
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
            try await Task.detached(priority: .userInitiated) {
                try ChunkedCopy.run(from: source, to: partURL, chunkSize: chunkSize, control: {
                    if flag.isSet { return .cancel }
                    // A pulled-out stick keeps the open descriptor alive, so the
                    // folder itself is what we poll (DESIGN §6).
                    return FileManager.default.fileExists(atPath: folderPath) ? .proceed : .driveGone
                }, progress: { written in
                    let snapshot = estimator.record(written: written, total: total)
                    Task { @MainActor in
                        store.updateOperationProgress(id: operationID, stage: nil, progress: snapshot)
                    }
                })
            }.value
        } catch let failure as ChunkedCopy.Failure {
            switch failure {
            case .cancelled: throw UpdateError.cancelled
            case .driveGone: throw UpdateError.driveVanished(snapshot.driveName)
            case .io(let message): throw UpdateError.copyFailed(message)
            }
        }

        // PRD F18: verify the copied size before it is given the real name.
        guard Self.fileSize(partURL) == local.sizeBytes else {
            try? manager.removeItem(at: partURL)
            throw UpdateError.copyFailed("The copied file is not the same size as the source. It was discarded; try again.")
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
