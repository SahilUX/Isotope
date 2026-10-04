import Foundation
import IsotopeCore

// MARK: - Errors (PRD F31: always the specific reason, always actionable)

enum FlashError: LocalizedError, Equatable {
    /// A safety gate refused the device (PRD F29).
    case gate(FlashGateFailure)
    case deviceNotFound(driveName: String)
    /// The confirmation the engine was handed is not from this session any more
    /// (PRD F31: never flash without a fresh confirmation).
    case confirmationExpired
    case notFlashable(entryName: String)
    case noDownloadURL(entryName: String)
    case downloadFailed(String)
    case checksumMismatch(fileName: String)
    case unmountFailed(String)
    case authorization(AuthopenError)
    case deviceVanished(deviceName: String)
    case writeFailed(String)
    case verificationMismatch
    case verificationFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .gate(let failure):
            return failure.reason
        case .deviceNotFound(let name):
            return "“\(name)” is not attached. Plug the device in and try again."
        case .confirmationExpired:
            return "The confirmation for this flash has expired. Confirm it again — nothing was written."
        case .notFlashable(let entryName):
            return "\(entryName) cannot be written to a flashed drive: a plain image copy of it does not produce a bootable device."
        case .noDownloadURL(let entryName):
            return "The latest release of \(entryName) does not publish a direct ISO link, so Isotope cannot download it automatically."
        case .downloadFailed(let message):
            return message
        case .checksumMismatch(let fileName):
            return "Checksum mismatch on “\(fileName)” — the download was corrupted or the source's checksum file is stale. The file was discarded and nothing was written to the device; try again."
        case .unmountFailed(let message):
            return "The device could not be unmounted, so nothing was written: \(message)"
        case .authorization(let error):
            return error.errorDescription
        case .deviceVanished(let name):
            return "“\(name)” was disconnected during the flash. The device is now in an undefined state and will not boot — reconnect it and flash it again."
        case .writeFailed(let message):
            return "Writing to the device failed: \(message). The device is in an undefined state — flash it again."
        case .verificationMismatch:
            return "The data read back from the device does not match the ISO. The device is in an undefined state — flash it again, and replace the stick if it keeps failing."
        case .verificationFailed(let message):
            return "The device could not be read back for verification: \(message). Flash it again to be sure of its contents."
        case .cancelled:
            return "The flash was cancelled. The device is in an undefined state — flash it again before using it."
        }
    }

    /// True when the failure happened after the first byte was written, so the
    /// stick is half-old, half-new and must be reflashed (DESIGN §9).
    var leavesDeviceUndefined: Bool {
        switch self {
        case .deviceVanished, .writeFailed, .verificationMismatch, .verificationFailed, .cancelled:
            return true
        case .gate, .deviceNotFound, .confirmationExpired, .notFlashable, .noDownloadURL,
             .downloadFailed, .checksumMismatch, .unmountFailed, .authorization:
            return false
        }
    }
}

// MARK: - Request & result

/// One confirmed flash (PRD F29/F30 — the UI has already shown the dialog).
struct FlashRequest: Sendable, Identifiable {
    var id: UUID = UUID()              // also the operation id
    var driveID: UUID
    var driveName: String
    var assignmentID: UUID
    var entryID: String
    var channelID: String
    /// "Arch Linux", for the UI and history.
    var title: String
    var release: Release
    /// The device the user picked in the confirmation dialog.
    var bsdName: String
    var deviceName: String
    /// `AppSettings.flashVerification` at confirmation time.
    var verifyAfterWrite: Bool
    /// PRD F31: the engine refuses a confirmation that is not from this session.
    var confirmedAt: Date = Date()
}

/// What a finished flash writes back to the drive record.
struct FlashedImage: Sendable, Equatable {
    var fileName: String
    var version: VersionToken
    var sizeBytes: Int64
    /// The volume UUID the freshly written image exposes, when it exposes one
    /// (PRD F27 — informational).
    var volumeUUID: String?
    var volumeName: String?
    var verified: Bool
}

enum FlashOutcome: Sendable {
    case success(FlashedImage)
    case failure(FlashError)
}

// MARK: - Engine

/// DESIGN §9 pipeline. One flash at a time per drive; the device I/O is behind
/// `FlashDeviceIO` so the whole pipeline is exercised in tests against a fake.
actor FlashEngine {
    private let store: AppStore
    private let downloads: ISOProviding
    private let io: FlashDeviceIO
    private let hashing: Hashing

    /// A confirmation older than this is stale — the device may have been
    /// swapped since the dialog was dismissed (PRD F31).
    static let confirmationLifetime: TimeInterval = 5 * 60

    private var chains: [UUID: Task<Void, Never>] = [:]
    private var cancellations: [UUID: CancellationFlag] = [:]
    private var cacheKeys: [UUID: String] = [:]
    /// Queued behind another flash of the same drive and not started yet, so a
    /// cancel can end it on the spot.
    private var waiting: [UUID: FlashRequest] = [:]

    /// 4 MiB, as DESIGN §9 step 5 specifies; overridable so tests can force many
    /// iterations over a small image.
    private(set) var chunkSize = 4 * 1024 * 1024

    init(store: AppStore, downloads: ISOProviding, io: FlashDeviceIO, hashing: Hashing) {
        self.store = store
        self.downloads = downloads
        self.io = io
        self.hashing = hashing
    }

    func setChunkSize(_ size: Int) { chunkSize = max(4096, size) }

    // MARK: Queueing

    func enqueue(_ request: FlashRequest) async {
        cancellations[request.id] = CancellationFlag()
        waiting[request.id] = request
        await store.beginFlashOperation(for: request)
        let previous = chains[request.driveID]
        chains[request.driveID] = Task { [weak self] in
            _ = await previous?.result
            await self?.perform(request)
        }
    }

    func drain() async {
        for chain in chains.values { _ = await chain.result }
    }

    func cancel(operationID: UUID) async {
        guard let flag = cancellations[operationID] else { return }
        flag.set()
        if let request = waiting.removeValue(forKey: operationID) {
            await store.finishFlashOperation(request: request, result: .failure(.cancelled))
            return
        }
        if let key = cacheKeys[operationID] { await downloads.cancel(cacheKey: key) }
    }

    // MARK: One flash

    private func perform(_ request: FlashRequest) async {
        defer {
            cancellations[request.id] = nil
            cacheKeys[request.id] = nil
        }
        // Already finished by `cancel` while it was queued.
        guard waiting.removeValue(forKey: request.id) != nil else { return }
        do {
            let flashed = try await execute(request)
            await store.finishFlashOperation(request: request, result: .success(flashed))
        } catch let error as FlashError {
            await store.finishFlashOperation(request: request, result: .failure(error))
        } catch let error as DownloadError {
            await store.finishFlashOperation(request: request, result: .failure(Self.map(error)))
        } catch is CancellationError {
            await store.finishFlashOperation(request: request, result: .failure(.cancelled))
        } catch {
            await store.finishFlashOperation(request: request,
                                             result: .failure(.writeFailed(error.localizedDescription)))
        }
    }

    private static func map(_ error: DownloadError) -> FlashError {
        switch error {
        case .checksumMismatch(let fileName): return .checksumMismatch(fileName: fileName)
        case .cancelled: return .cancelled
        case .transport, .sizeMismatch: return .downloadFailed(error.localizedDescription)
        }
    }

    private func execute(_ request: FlashRequest) async throws -> FlashedImage {
        let flag = cancellations[request.id] ?? CancellationFlag()

        // 0 — the confirmation has to be this session's (PRD F31).
        guard Date().timeIntervalSince(request.confirmedAt) <= Self.confirmationLifetime else {
            throw FlashError.confirmationExpired
        }

        // 1 — gates before anything is downloaded, so an ineligible device is
        //     refused in a second rather than after a 4 GB download.
        try await checkGates(request, isoSizeBytes: request.release.sizeBytes)

        // 2 — the image itself: download, checksum-verify and cache it exactly
        //     the way a Ventoy update does (PRD F29 "identical to F18").
        guard let sourceURL = request.release.isoURL,
              let finalName = DownloadArtifact.placedFileName(for: request.release)
        else { throw FlashError.noDownloadURL(entryName: request.title) }
        let publishedName = request.release.fileName.isEmpty
            ? sourceURL.lastPathComponent : request.release.fileName
        let isoRequest = ISORequest(
            sourceURL: sourceURL, fileName: publishedName, sha256: request.release.sha256,
            expectedSizeBytes: request.release.sizeBytes,
            context: DownloadContext(driveID: request.driveID, driveName: request.driveName,
                                     entryID: request.entryID, channelID: request.channelID,
                                     assignmentID: request.assignmentID))
        cacheKeys[request.id] = isoRequest.cacheKey
        await store.setOperationCacheKey(id: request.id, key: isoRequest.cacheKey)
        if flag.isSet { throw FlashError.cancelled }

        let operationID = request.id
        let store = self.store
        let local = try await downloads.ensureLocalISO(isoRequest) { stage, progress in
            Task { @MainActor in
                store.updateOperationProgress(id: operationID, stage: stage, progress: progress)
            }
        }
        // PRD F47: the image is on the device once this returns; the cached
        // copy is then a duplicate of something the user is holding in their
        // hand. `flashed` is set only on the success path, so a failed flash
        // keeps the download for the retry.
        var flashed = false
        defer {
            Task { [downloads, store, flashed] in
                let wanted = await store.discardsCacheAfterPlacement
                await downloads.endUse(cacheKey: local.cacheKey, discard: flashed && wanted)
            }
        }
        if flag.isSet { throw FlashError.cancelled }

        // 3 — gates again, now that the real image size is known and the
        //     download has given the user time to unplug things.
        try await checkGates(request, isoSizeBytes: local.sizeBytes)

        // 4 — unmount, then write.
        do {
            try await io.unmountDisk(bsdName: request.bsdName)
        } catch {
            throw FlashError.unmountFailed(error.localizedDescription)
        }

        await store.updateOperationPhase(id: request.id, phase: .flashing, totalBytes: local.sizeBytes)
        let handle: FlashDeviceWriting
        do {
            handle = try await io.openForWriting(bsdName: request.bsdName)
        } catch let error as AuthopenError {
            throw FlashError.authorization(error)
        }
        let digest = try await writeImage(local: local, handle: handle,
                                          operationID: request.id, deviceName: request.deviceName,
                                          flag: flag)

        // 5 — read-back verification (PRD F29, Settings-controlled).
        var verified = false
        if request.verifyAfterWrite {
            await store.updateOperationPhase(id: request.id, phase: .verifyingDevice,
                                             totalBytes: local.sizeBytes)
            try await verifyDevice(request: request, byteCount: local.sizeBytes,
                                   expectedDigest: digest, operationID: request.id, flag: flag)
            verified = true
        }

        // 6 — remount to pick up the new volume UUID (PRD F27, informational).
        await store.updateOperationPhase(id: request.id, phase: .finishing, totalBytes: local.sizeBytes)
        let remounted = await io.remount(bsdName: request.bsdName)
        flashed = true
        return FlashedImage(fileName: finalName, version: request.release.version,
                            sizeBytes: local.sizeBytes, volumeUUID: remounted.volumeUUID,
                            volumeName: remounted.volumeName, verified: verified)
    }

    /// PRD F29/F31: the gates run against the device's *current* state, every
    /// time, never against what registration recorded.
    private func checkGates(_ request: FlashRequest, isoSizeBytes: Int64?) async throws {
        guard let description = await io.describe(bsdName: request.bsdName) else {
            throw FlashError.deviceNotFound(driveName: request.deviceName)
        }
        if let failure = FlashSafetyGate.evaluate(device: description, isoSizeBytes: isoSizeBytes) {
            throw FlashError.gate(failure)
        }
    }

    // MARK: Streaming

    /// Streams the cached ISO to the device in `chunkSize` slices, hashing as it
    /// goes so verification costs one pass rather than two, and reporting
    /// bytes/speed/ETA per chunk (DESIGN §9 step 5).
    private func writeImage(local: LocalISO, handle: FlashDeviceWriting, operationID: UUID,
                            deviceName: String, flag: CancellationFlag) async throws -> String {
        let store = self.store
        let hashing = self.hashing
        let chunkSize = self.chunkSize
        let total = local.sizeBytes
        let source = local.url
        do {
            return try await Task.detached(priority: .userInitiated) { () throws -> String in
                let input = try FileHandle(forReadingFrom: source)
                defer { try? input.close() }
                let hasher = hashing.makeHasher()
                let rate = FlashRateBox()
                let throttle = ProgressThrottle()
                var written: Int64 = 0
                while true {
                    if flag.isSet { throw FlashError.cancelled }
                    let chunk = try input.read(upToCount: chunkSize) ?? Data()
                    if chunk.isEmpty { break }
                    try handle.write(chunk)
                    hasher.update(chunk)
                    written += Int64(chunk.count)
                    let progress = rate.record(written: written, total: total)
                    guard throttle.shouldEmit(force: written >= total) else { continue }
                    Task { @MainActor in
                        store.updateOperationProgress(id: operationID, stage: nil, progress: progress)
                    }
                }
                try handle.finish()
                return hasher.finalizeHex()
            }.value
        } catch {
            handle.abort()
            throw Self.writeError(error, deviceName: deviceName)
        }
    }

    private static func writeError(_ error: Error, deviceName: String) -> FlashError {
        switch error {
        case let flash as FlashError:
            return flash
        case let io as FlashIOError:
            switch io {
            case .deviceVanished: return .deviceVanished(deviceName: deviceName)
            case .io(let message): return .writeFailed(message)
            }
        default:
            return .writeFailed(error.localizedDescription)
        }
    }

    /// Re-opens the device read-only (a second authorisation, by design: reusing
    /// the write descriptor would not prove the bytes reached the medium), reads
    /// back exactly the image's length and compares digests.
    private func verifyDevice(request: FlashRequest, byteCount: Int64, expectedDigest: String,
                              operationID: UUID, flag: CancellationFlag) async throws {
        let reader: FlashDeviceReading
        do {
            reader = try await io.openForReading(bsdName: request.bsdName)
        } catch let error as AuthopenError {
            throw FlashError.authorization(error)
        } catch {
            throw FlashError.verificationFailed(error.localizedDescription)
        }
        let store = self.store
        let hashing = self.hashing
        let chunkSize = self.chunkSize
        let digest: String
        do {
            digest = try await Task.detached(priority: .userInitiated) { () throws -> String in
                defer { reader.close() }
                let hasher = hashing.makeHasher()
                let rate = FlashRateBox()
                let throttle = ProgressThrottle()
                var read: Int64 = 0
                while read < byteCount {
                    if flag.isSet { throw FlashError.cancelled }
                    let want = Int(min(Int64(chunkSize), byteCount - read))
                    let chunk = try reader.read(upTo: want)
                    if chunk.isEmpty { throw FlashIOError.deviceVanished }
                    hasher.update(chunk)
                    read += Int64(chunk.count)
                    let progress = rate.record(written: read, total: byteCount)
                    Task { @MainActor in
                        store.updateOperationProgress(id: operationID, stage: nil, progress: progress)
                    }
                }
                return hasher.finalizeHex()
            }.value
        } catch let error as FlashError {
            throw error
        } catch FlashIOError.deviceVanished {
            throw FlashError.deviceVanished(deviceName: request.deviceName)
        } catch {
            throw FlashError.verificationFailed(error.localizedDescription)
        }
        guard checksumsMatch(digest, expectedDigest) else { throw FlashError.verificationMismatch }
    }
}

/// Same trick as `UpdateEngine`'s `RateBox`: carries the rate estimator across
/// the boundary between the detached write loop and the main-actor UI updates.
private final class FlashRateBox: @unchecked Sendable {
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
