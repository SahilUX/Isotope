import Foundation
import IsotopeCore

// MARK: - Contract

/// What an update operation needs: "give me this ISO on local disk".
/// A protocol so `UpdateEngine` can be tested without a network (DESIGN §7).
protocol ISOProviding: Sendable {
    func ensureLocalISO(_ request: ISORequest,
                        progress: @escaping @Sendable (DownloadStage, TransferProgress) -> Void)
        async throws -> LocalISO
    /// Balances the cache hold `ensureLocalISO` took, so eviction can resume.
    /// `discard` (PRD F47) additionally deletes the file now that it has been
    /// placed, provided nothing else is still using it; the return is the bytes
    /// that freed.
    @discardableResult
    func endUse(cacheKey: String, discard: Bool) async -> Int64
    func pause(cacheKey: String) async
    func resume(cacheKey: String) async
    func cancel(cacheKey: String) async
}

struct ISORequest: Sendable, Hashable {
    var sourceURL: URL
    /// Name as published — may be an archive (`…​.iso.zip`).
    var fileName: String
    var sha256: String?
    var expectedSizeBytes: Int64?
    /// Only used to describe the download if it has to be resumed after a quit.
    var context: DownloadContext?

    init(sourceURL: URL, fileName: String, sha256: String? = nil,
         expectedSizeBytes: Int64? = nil, context: DownloadContext? = nil) {
        self.sourceURL = sourceURL
        self.fileName = fileName
        self.sha256 = sha256
        self.expectedSizeBytes = expectedSizeBytes
        self.context = context
    }

    var cacheKey: String {
        DownloadArtifact.cacheKey(sha256: sha256, sourceURL: sourceURL, fileName: fileName)
    }

    /// The name the ISO takes once any archive is unwrapped.
    var isoFileName: String { DownloadArtifact.isoName(fromArchive: fileName) }
}

struct DownloadContext: Sendable, Hashable {
    var driveID: UUID
    var driveName: String
    var entryID: String
    var channelID: String
    var assignmentID: UUID
}

/// A ready-to-copy ISO in the local cache. The caller holds a cache retain
/// until it calls `endUse`.
struct LocalISO: Sendable, Hashable {
    var url: URL
    var fileName: String
    var sizeBytes: Int64
    var cacheKey: String
}

enum DownloadStage: String, Sendable, Hashable {
    case cached, downloading, verifying, extracting
}

enum DownloadError: LocalizedError, Equatable {
    case checksumMismatch(fileName: String)
    case cancelled
    case transport(String)
    case sizeMismatch(expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case .checksumMismatch(let fileName):
            // PRD F25's worked example, verbatim in spirit.
            return "Checksum mismatch on “\(fileName)” — the download was corrupted or the source's checksum file is stale. The file was discarded; try again."
        case .cancelled:
            return "The download was cancelled."
        case .transport(let message):
            return "The download failed: \(message)"
        case .sizeMismatch(let expected, let actual):
            let e = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
            let a = ByteCountFormatter.string(fromByteCount: actual, countStyle: .file)
            return "The download finished at \(a) but the source advertised \(e). The file was discarded; try again."
        }
    }
}

// MARK: - Manager

/// DESIGN §4.4. Owns the `URLSession`, the concurrency limit, resume data,
/// verification and the hand-off into `ISOCache`.
///
/// Requests are keyed by cache key, so two drives that need the same ISO share
/// one download and two copies (PRD F20, DESIGN §6).
actor DownloadManager: ISOProviding {
    private let cache: ISOCache
    private let hashing: Hashing
    private let extractor: ArchiveExtracting
    private let locations: CacheLocations
    private let session: URLSession
    private let sessionDelegate: DownloadSessionDelegate

    /// PRD F19: max 2 concurrent downloads, configurable.
    private var maxConcurrent: Int
    private var runningCount = 0
    /// Resumed with `true` when handed a slot, `false` when cancelled first.
    private var slotWaiters: [(key: String, continuation: CheckedContinuation<Bool, Never>)] = []
    /// Set while a download's checksum is being computed, so cancel can stop it.
    private var verifyFlags: [String: CancellationFlag] = [:]

    private var inFlight: [String: Task<LocalISO, Error>] = [:]
    private var observers: [String: [UUID: @Sendable (DownloadStage, TransferProgress) -> Void]] = [:]
    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    /// What each in-flight transfer is for, so a quit can record it as
    /// interrupted without waiting for the delegate callback (PRD F19).
    private var activeRequests: [String: ISORequest] = [:]
    private var lastKnownBytes: [String: Int64] = [:]
    /// Parked: cleared by `resume`, checked before a transfer parks.
    private var pausedKeys: Set<String> = []
    /// Pause asked for but not yet reported by the session delegate. Cleared
    /// when the transfer reports, so a resume that beats the callback cannot
    /// make the pause look like a cancellation.
    private var pauseRequested: Set<String> = []
    private var cancelledKeys: Set<String> = []
    private var pauseWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var interrupted: [String: InterruptedDownload] = [:]

    init(cache: ISOCache,
         locations: CacheLocations,
         hashing: Hashing,
         extractor: ArchiveExtracting = DittoArchiveExtractor(),
         maxConcurrent: Int = 2,
         sessionConfiguration: URLSessionConfiguration = .default) {
        self.cache = cache
        self.locations = locations
        self.hashing = hashing
        self.extractor = extractor
        self.maxConcurrent = max(1, maxConcurrent)
        try? locations.ensureDirectoriesExist()
        let delegate = DownloadSessionDelegate(staging: locations.resume)
        self.sessionDelegate = delegate
        // No timeoutIntervalForResource: a 6 GB ISO on a slow line is normal.
        sessionConfiguration.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: sessionConfiguration,
                                  delegate: delegate, delegateQueue: nil)
        let stored = (try? JSONStore.load([InterruptedDownload].self, from: locations.resumeManifest)) ?? nil
        self.interrupted = Dictionary(uniqueKeysWithValues: (stored ?? []).map { ($0.id, $0) })
    }

    func setMaxConcurrent(_ value: Int) {
        maxConcurrent = max(1, value)
        // A raised limit should let queued work start immediately.
        while runningCount < maxConcurrent, !slotWaiters.isEmpty {
            slotWaiters.removeFirst().continuation.resume(returning: true)
            runningCount += 1
        }
    }

    // MARK: - Resume offers (PRD F19)

    /// Interrupted downloads with resume data still on disk, newest first.
    func resumableDownloads() -> [InterruptedDownload] {
        interrupted.values
            .filter { FileManager.default.fileExists(atPath: resumeFileURL(key: $0.id).path) }
            .sorted { $0.interruptedAt > $1.interruptedAt }
    }

    func discardResumable(key: String) {
        interrupted[key] = nil
        try? FileManager.default.removeItem(at: resumeFileURL(key: key))
        persistInterrupted()
    }

    // MARK: - Clean quit (PRD F19)

    /// Called from `applicationShouldTerminate`: stop every in-flight transfer
    /// the way a pause does — producing resume data — and write both the resume
    /// files and the manifest before the process goes away, so a relaunch can
    /// offer to carry on.
    ///
    /// Returns the keys it parked, which is what the tests assert on.
    @discardableResult
    func suspendForQuit() async -> [String] {
        let keys = activeTasks.keys.sorted()
        guard !keys.isEmpty else { return [] }
        var collected: [(key: String, data: Data?)] = []
        for key in keys {
            guard let task = activeTasks[key] else { continue }
            pausedKeys.insert(key)
            pauseRequested.insert(key)
            let data: Data? = await withCheckedContinuation { continuation in
                task.cancel(byProducingResumeData: { continuation.resume(returning: $0) })
            }
            collected.append((key, data))
        }
        for (key, data) in collected {
            if let data { storeResumeDataSync(data, key: key) }
            guard let request = activeRequests[key] else { continue }
            interrupted[key] = interruptedRecord(request: request,
                                                 bytes: lastKnownBytes[key] ?? 0,
                                                 paused: true)
        }
        persistInterrupted()
        return collected.map(\.key)
    }

    // MARK: - Main entry point

    func ensureLocalISO(_ request: ISORequest,
                        progress: @escaping @Sendable (DownloadStage, TransferProgress) -> Void)
        async throws -> LocalISO {
        let key = request.cacheKey

        // Fast path: already cached and verified (PRD F20).
        if let ready = await cachedISO(for: request) {
            progress(.cached, TransferProgress(completedBytes: ready.sizeBytes,
                                               totalBytes: ready.sizeBytes))
            await cache.retain(key: ready.cacheKey)
            return ready
        }

        let observerID = UUID()
        observers[key, default: [:]][observerID] = progress
        defer { observers[key]?[observerID] = nil }

        // Coalesce: a second drive needing the same ISO joins the existing run.
        let task: Task<LocalISO, Error>
        if let existing = inFlight[key] {
            task = existing
        } else {
            cancelledKeys.remove(key)
            task = Task { [weak self] in
                guard let self else { throw DownloadError.cancelled }
                return try await self.run(request)
            }
            inFlight[key] = task
        }
        do {
            let result = try await task.value
            await cache.retain(key: result.cacheKey)
            return result
        } catch {
            throw error
        }
    }

    /// PRD F47: releasing the hold is the moment the file becomes deletable, so
    /// it is also the moment to delete it — the cache exists to save a second
    /// download, not to accumulate ISOs the user already has on a stick.
    /// Returns the bytes reclaimed, for the history line.
    @discardableResult
    func endUse(cacheKey: String, discard: Bool = false) async -> Int64 {
        await cache.release(key: cacheKey)
        guard discard, !cacheKey.isEmpty else { return 0 }
        return await cache.discardIfUnused(key: cacheKey)
    }

    // MARK: - Pause / resume / cancel

    func pause(cacheKey: String) {
        guard let task = activeTasks[cacheKey] else { return }
        pausedKeys.insert(cacheKey)
        pauseRequested.insert(cacheKey)
        task.cancel(byProducingResumeData: { [weak self] data in
            guard let self else { return }
            Task { await self.storeResumeData(data, key: cacheKey) }
        })
    }

    func resume(cacheKey: String) {
        pausedKeys.remove(cacheKey)
        let waiters = pauseWaiters.removeValue(forKey: cacheKey) ?? []
        for waiter in waiters { waiter.resume() }
    }

    func cancel(cacheKey: String) {
        cancelledKeys.insert(cacheKey)
        pausedKeys.remove(cacheKey)
        pauseRequested.remove(cacheKey)
        activeTasks[cacheKey]?.cancel()
        verifyFlags[cacheKey]?.set()
        for waiter in pauseWaiters.removeValue(forKey: cacheKey) ?? [] { waiter.resume() }
        // Still queued for a download slot: leave the queue without taking one.
        let queued = slotWaiters.filter { $0.key == cacheKey }
        slotWaiters.removeAll { $0.key == cacheKey }
        for waiter in queued { waiter.continuation.resume(returning: false) }
        inFlight[cacheKey]?.cancel()
    }

    // MARK: - Pipeline

    private func cachedISO(for request: ISORequest) async -> LocalISO? {
        guard let artifact = await cache.hit(sourceURL: request.sourceURL, sha256: request.sha256)
        else { return nil }
        // An archive's cache entry is the zip; the usable ISO is its child.
        if DownloadArtifact.isZipArchive(artifact.fileName) || DownloadArtifact.isZipArchive(request.fileName) {
            guard let child = await cache.extracted(fromKey: artifact.key) else { return nil }
            return LocalISO(url: await cache.fileURL(child), fileName: request.isoFileName,
                            sizeBytes: child.sizeBytes, cacheKey: child.key)
        }
        return LocalISO(url: await cache.fileURL(artifact), fileName: request.isoFileName,
                        sizeBytes: artifact.sizeBytes, cacheKey: artifact.key)
    }

    private func run(_ request: ISORequest) async throws -> LocalISO {
        let key = request.cacheKey
        defer {
            inFlight[key] = nil
            observers[key] = nil
            activeTasks[key] = nil
        }
        // The concurrency slot is held by `download` around each transfer only:
        // a paused download must not keep a slot (PRD F19 — two paused
        // downloads would otherwise wedge the queue at max-2).
        let downloaded = try await download(request)
        do {
            try await verify(downloaded, request: request)
        } catch {
            // PRD F25: a corrupt download is discarded, never cached.
            try? FileManager.default.removeItem(at: downloaded)
            throw error
        }
        discardResumable(key: key)

        let artifact = try await cache.adopt(fileAt: downloaded, key: key, fileName: request.fileName,
                                             sha256: request.sha256, sourceURL: request.sourceURL)
        guard DownloadArtifact.isZipArchive(request.fileName) else {
            return LocalISO(url: await cache.fileURL(artifact), fileName: request.isoFileName,
                            sizeBytes: artifact.sizeBytes, cacheKey: artifact.key)
        }
        return try await unpack(artifact, request: request)
    }

    /// Memtest86+ is only published as a zip; unpack once and cache the ISO so a
    /// second drive copies it straight out of the cache.
    private func unpack(_ archive: CachedArtifact, request: ISORequest) async throws -> LocalISO {
        emit(request.cacheKey, .extracting, TransferProgress(completedBytes: 0))
        let archiveURL = await cache.fileURL(archive)
        let scratch = locations.root.appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let extractor = self.extractor
        let extracted = try await Task.detached(priority: .userInitiated) {
            try extractor.extractISO(from: archiveURL, into: scratch)
        }.value
        let childKey = DownloadArtifact.extractedCacheKey(parentKey: archive.key)
        let child = try await cache.adopt(fileAt: extracted, key: childKey,
                                          fileName: request.isoFileName,
                                          sha256: nil, sourceURL: nil,
                                          derivedFromKey: archive.key)
        return LocalISO(url: await cache.fileURL(child), fileName: request.isoFileName,
                        sizeBytes: child.sizeBytes, cacheKey: child.key)
    }

    /// Runs the transfer, honouring pause (which parks until `resume`) and
    /// cancel, and persisting resume data whenever it stops early.
    ///
    /// The concurrency slot is taken around the transfer itself and given back
    /// while the download is parked, so paused downloads never starve queued
    /// ones (PRD F19).
    private func download(_ request: ISORequest) async throws -> URL {
        let key = request.cacheKey
        var resumeData = loadResumeData(key: key)
        while true {
            if cancelledKeys.contains(key) { throw DownloadError.cancelled }
            try await acquireSlot(key: key)
            // Cancelled while it waited for the slot it has just been given.
            if cancelledKeys.contains(key) {
                releaseSlot()
                throw DownloadError.cancelled
            }
            do {
                let file = try await transfer(request, resumeData: resumeData)
                releaseSlot()
                return file
            } catch let error as DownloadPause {
                releaseSlot()
                resumeData = error.resumeData ?? loadResumeData(key: key)
                await parkUntilResumed(key: key)
                if cancelledKeys.contains(key) { throw DownloadError.cancelled }
            } catch {
                releaseSlot()
                throw error
            }
        }
    }

    private func transfer(_ request: ISORequest, resumeData: Data?) async throws -> URL {
        let key = request.cacheKey
        let expected = request.expectedSizeBytes
        let progressBox = ProgressBox()
        let throttle = ProgressThrottle()

        return try await withCheckedThrowingContinuation { continuation in
            let task: URLSessionDownloadTask = resumeData.map { session.downloadTask(withResumeData: $0) }
                ?? session.downloadTask(with: request.sourceURL)
            sessionDelegate.register(task, handlers: DownloadSessionDelegate.Handlers(
                progress: { [weak self] written, total in
                    let snapshot = progressBox.record(written: written, total: total > 0 ? total : expected)
                    // URLSession reports every few kilobytes — hundreds of times
                    // a second on a fast line. Forwarding each one queued work on
                    // this actor ahead of Cancel and Pause, and rebuilt the
                    // Activity row so often its buttons dropped clicks (PRD F62
                    // already throttles the copy for the same reason).
                    guard throttle.shouldEmit(force: snapshot.total.map { written >= $0 } ?? false)
                    else { return }
                    Task { await self?.reportProgress(key: key, snapshot: snapshot) }
                },
                finish: { [weak self] result in
                    Task { await self?.finishTransfer(key: key, result: result,
                                                      request: request,
                                                      bytes: progressBox.written,
                                                      continuation: continuation) }
                }))
            activeTasks[key] = task
            activeRequests[key] = request
            task.resume()
        }
    }

    private func reportProgress(key: String, snapshot: (written: Int64, total: Int64?)) {
        lastKnownBytes[key] = snapshot.written
        var estimator = rateEstimators[key] ?? TransferRateEstimator()
        estimator.record(totalBytes: snapshot.written, at: Date())
        rateEstimators[key] = estimator
        let remaining = (snapshot.total ?? 0) - snapshot.written
        emit(key, .downloading, TransferProgress(completedBytes: snapshot.written,
                                                 totalBytes: snapshot.total,
                                                 bytesPerSecond: estimator.bytesPerSecond,
                                                 eta: estimator.eta(remainingBytes: remaining)))
    }

    private var rateEstimators: [String: TransferRateEstimator] = [:]

    private func finishTransfer(key: String, result: Result<URL, Error>, request: ISORequest,
                                bytes: Int64,
                                continuation: CheckedContinuation<URL, Error>) {
        activeTasks[key] = nil
        activeRequests[key] = nil
        rateEstimators[key] = nil
        switch result {
        case .success(let url):
            continuation.resume(returning: url)
        case .failure(let error):
            let nsError = error as NSError
            let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            if pauseRequested.remove(key) != nil {
                // Deliberate pause: park, keep the bytes. (`pausedKeys` may
                // already have been cleared by a resume that beat this callback,
                // which is why the request flag is what decides.)
                record(request: request, bytes: bytes, paused: true)
                continuation.resume(throwing: DownloadPause(resumeData: data))
                return
            }
            if cancelledKeys.contains(key) || nsError.code == NSURLErrorCancelled {
                discardResumable(key: key)
                continuation.resume(throwing: DownloadError.cancelled)
                return
            }
            // A real failure keeps its resume data so relaunch can offer it (F19).
            if let data { storeResumeDataSync(data, key: key) }
            record(request: request, bytes: bytes, paused: false)
            continuation.resume(throwing: DownloadError.transport(error.localizedDescription))
        }
    }

    private func parkUntilResumed(key: String) async {
        guard pausedKeys.contains(key) else { return }
        await withCheckedContinuation { continuation in
            pauseWaiters[key, default: []].append(continuation)
        }
    }

    private func verify(_ file: URL, request: ISORequest) async throws {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        // Only a hard mismatch is fatal; many mirrors round or omit the size.
        if let expected = request.expectedSizeBytes, expected > 0, request.sha256 == nil,
           size > 0, abs(expected - size) > max(expected / 100, 1_048_576) {
            throw DownloadError.sizeMismatch(expected: expected, actual: size)
        }
        guard let expectedHash = request.sha256, !expectedHash.isEmpty else { return }
        emit(request.cacheKey, .verifying, TransferProgress(completedBytes: 0, totalBytes: size))
        let hashing = self.hashing
        let key = request.cacheKey
        let flag = CancellationFlag()
        if cancelledKeys.contains(key) { flag.set() }
        verifyFlags[key] = flag
        defer { verifyFlags[key] = nil }
        // Hashing knows the file size up front, so verification reports real
        // progress (DESIGN §5). Reported every 16 MB — often enough to move a
        // bar, rare enough not to flood the actor.
        let digest: String
        do {
            digest = try await Task.detached(priority: .userInitiated) { [weak self] in
                var nextReport: Int64 = 16 << 20
                return try hashing.sha256Hex(ofFileAt: file, shouldContinue: { !flag.isSet },
                                             progress: { read in
                    guard read >= nextReport else { return }
                    nextReport = read + (16 << 20)
                    Task { await self?.emitVerifyProgress(key: key, read: read, total: size) }
                })
            }.value
        } catch HashingError.cancelled {
            throw DownloadError.cancelled
        }
        guard checksumsMatch(digest, expectedHash) else {
            throw DownloadError.checksumMismatch(fileName: request.fileName)
        }
        emit(request.cacheKey, .verifying, TransferProgress(completedBytes: size, totalBytes: size))
    }

    private func emitVerifyProgress(key: String, read: Int64, total: Int64) {
        emit(key, .verifying, TransferProgress(completedBytes: read, totalBytes: total))
    }

    // MARK: - Slots

    private func acquireSlot(key: String) async throws {
        if runningCount < maxConcurrent {
            runningCount += 1
            return
        }
        let granted = await withCheckedContinuation { continuation in
            slotWaiters.append((key, continuation))
        }
        guard granted else { throw DownloadError.cancelled }
    }

    private func releaseSlot() {
        if slotWaiters.isEmpty {
            runningCount = max(0, runningCount - 1)
        } else {
            // Hand the slot straight over rather than decrementing and racing.
            slotWaiters.removeFirst().continuation.resume(returning: true)
        }
    }

    // MARK: - Resume bookkeeping

    private func resumeFileURL(key: String) -> URL {
        locations.resume.appendingPathComponent("\(key).resume")
    }

    private func loadResumeData(key: String) -> Data? {
        try? Data(contentsOf: resumeFileURL(key: key))
    }

    private func storeResumeData(_ data: Data?, key: String) {
        guard let data else { return }
        storeResumeDataSync(data, key: key)
    }

    private func storeResumeDataSync(_ data: Data, key: String) {
        try? FileManager.default.createDirectory(at: locations.resume, withIntermediateDirectories: true)
        try? data.write(to: resumeFileURL(key: key), options: [.atomic])
    }

    private func record(request: ISORequest, bytes: Int64, paused: Bool) {
        interrupted[request.cacheKey] = interruptedRecord(request: request, bytes: bytes,
                                                          paused: paused)
        persistInterrupted()
    }

    private func interruptedRecord(request: ISORequest, bytes: Int64,
                                   paused: Bool) -> InterruptedDownload {
        let context = request.context
        return InterruptedDownload(
            id: request.cacheKey, sourceURL: request.sourceURL, fileName: request.fileName,
            sha256: request.sha256, expectedSizeBytes: request.expectedSizeBytes,
            bytesDownloaded: bytes, driveID: context?.driveID, driveName: context?.driveName,
            entryID: context?.entryID, channelID: context?.channelID,
            assignmentID: context?.assignmentID, interruptedAt: Date(), wasPaused: paused)
    }

    private func persistInterrupted() {
        try? JSONStore.save(Array(interrupted.values), to: locations.resumeManifest)
    }

    private func emit(_ key: String, _ stage: DownloadStage, _ progress: TransferProgress) {
        guard let registered = observers[key] else { return }
        for observer in registered.values { observer(stage, progress) }
    }
}

/// Thrown internally when a transfer stops because the user paused it.
private struct DownloadPause: Error {
    var resumeData: Data?
}

/// Progress counters shared with the `URLSession` delegate queue.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _written: Int64 = 0
    private var _total: Int64?

    var written: Int64 { lock.withLock { _written } }

    func record(written: Int64, total: Int64?) -> (written: Int64, total: Int64?) {
        lock.withLock {
            _written = written
            if let total, total > 0 { _total = total }
            return (_written, _total)
        }
    }
}

// MARK: - URLSession delegate

/// Bridges `URLSession`'s delegate callbacks (arbitrary queue) into the actor.
/// `didFinishDownloadingTo` must move the file before it returns, so that step
/// happens here rather than being hopped onto the actor.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Handlers {
        var progress: @Sendable (Int64, Int64) -> Void
        var finish: @Sendable (Result<URL, Error>) -> Void
    }

    private let lock = NSLock()
    private var handlers: [Int: Handlers] = [:]
    private var finished: Set<Int> = []
    private let staging: URL

    init(staging: URL) {
        self.staging = staging
        super.init()
    }

    func register(_ task: URLSessionTask, handlers: Handlers) {
        lock.withLock {
            self.handlers[task.taskIdentifier] = handlers
            self.finished.remove(task.taskIdentifier)
        }
    }

    private func complete(_ identifier: Int, _ result: Result<URL, Error>) {
        let handler: Handlers? = lock.withLock {
            guard !finished.contains(identifier) else { return nil }
            finished.insert(identifier)
            return handlers.removeValue(forKey: identifier)
        }
        handler?.finish(result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let handler = lock.withLock { handlers[downloadTask.taskIdentifier] }
        handler?.progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let destination = staging.appendingPathComponent("download-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
            complete(downloadTask.taskIdentifier, .success(destination))
        } catch {
            complete(downloadTask.taskIdentifier, .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            // Success was already reported by didFinishDownloadingTo.
            lock.withLock { _ = handlers.removeValue(forKey: task.taskIdentifier) }
            return
        }
        complete(task.taskIdentifier, .failure(error))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
