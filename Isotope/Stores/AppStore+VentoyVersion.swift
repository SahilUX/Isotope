import Foundation
import IsotopeCore

/// One VTOYEFI read that has started and not yet returned (PRD F74).
struct VentoyProbeHold: Equatable, Sendable {
    var driveID: UUID
    var volumeUUID: String
    /// The whole disk the device list had the drive on, or nil when it was not
    /// listed (then every flash waits for the read).
    var wholeDisk: String?
    /// True until the read returns or the store's cap passes. While true, no
    /// flash, update, copy, delete or eject touches that physical device.
    var holdsDevice: Bool = true
}

/// PRD F74: the Ventoy release on each connected Ventoy drive.
///
/// Read once per connect, on a dedicated serial queue, and kept in memory
/// only: it is not written to `drives.json`, so no on-disk format changes. The
/// exclusion runs both ways: a read does not start while the drive (or any
/// flash) is busy, and while a read holds a physical device, nothing that
/// writes to, deletes from or ejects that device starts (the engines wait,
/// Delete and Eject refuse). The store gives up on a read after
/// `ventoyVersionReadCap`, so nothing waits on it longer than that.
extension AppStore {
    /// Where every read runs: blocking waits on `mount`/`umount` stay off the
    /// main actor and off Swift's shared task threads, and two reads never
    /// overlap.
    nonisolated static let ventoyVersionQueue = DispatchQueue(label: "Isotope.VentoyVersion", qos: .utility)

    /// What to show for a drive: nil while connected but not read yet (or not
    /// connected at all).
    func ventoyVersion(for drive: ManagedDrive) -> VentoyVersionReading? {
        guard !drive.isFlashed, isConnected(drive) else { return nil }
        return ventoyVersions[drive.id]
    }

    /// True while a read holds this drive's physical device: the same
    /// registration, the same volume, or the same whole disk (a stick can be
    /// registered as a Ventoy drive and as a flashed drive at once).
    func isReadingVentoyVersion(_ drive: ManagedDrive) -> Bool {
        let disk = physicalDisk(of: drive)
        return ventoyProbes.values.contains { hold in
            guard hold.holdsDevice else { return false }
            if hold.driveID == drive.id { return true }
            if !drive.volumeUUID.isEmpty, hold.volumeUUID == drive.volumeUUID { return true }
            if let disk, disk == hold.wholeDisk { return true }
            // A read whose disk is unknown might be on any flashed stick.
            return drive.isFlashed && hold.wholeDisk == nil
        }
    }

    /// True while a read holds the whole disk `bsdName` (or a disk it could
    /// not name, which might be this one).
    func isReadingVentoyVersion(bsdName: String) -> Bool {
        ventoyProbes.values.contains { $0.holdsDevice && ($0.wholeDisk == nil || $0.wholeDisk == bsdName) }
    }

    /// The whole disk a drive is attached at right now, from the device list.
    func physicalDisk(of drive: ManagedDrive) -> String? {
        if drive.isFlashed { return attachedDevice(for: drive)?.bsdName }
        return attachedDevices.first { $0.volumeUUIDs.contains(drive.volumeUUID) }?.bsdName
    }

    /// Called by `UpdateEngine` and `FlashEngine` just before an operation
    /// starts: returns once no read holds the drive or `bsdName`. Bounded by
    /// the cap, after which the store has released every hold anyway.
    func waitForVentoyVersionReads(driveID: UUID, bsdName: String? = nil) async {
        let deadline = Date().addingTimeInterval(ventoyVersionReadCap + 1)
        while Date() < deadline {
            let drive = drive(id: driveID)
            let held = drive.map(isReadingVentoyVersion) == true
                || bsdName.map { isReadingVentoyVersion(bsdName: $0) } == true
            guard held else { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Starts the read for a connected Ventoy drive unless this connect has
    /// already been read, a read for it is running (or still winding down
    /// after the cap), or the drive is busy. Called after every scan; almost
    /// every call does nothing.
    func refreshVentoyVersion(driveID: UUID) {
        guard ventoyVersionReader.isEnabled, let drive = drive(id: driveID), !drive.isFlashed,
              let info = volumeInfo(for: drive),
              ventoyVersions[driveID] == nil, ventoyVersionReads[driveID] == nil,
              !ventoyProbes.values.contains(where: { $0.driveID == driveID }),
              !blocksVentoyVersionRead(drive)
        else { return }
        let token = UUID()
        let device = attachedDevices.first { $0.volumeUUIDs.contains(drive.volumeUUID) }
        let expected = VentoyExpectedIdentity(volumeUUID: drive.volumeUUID, wholeDisk: device?.bsdName,
                                              hardwareID: device?.hardwareID)
        ventoyVersionReads[driveID] = token
        ventoyProbes[token] = VentoyProbeHold(driveID: driveID, volumeUUID: drive.volumeUUID,
                                              wholeDisk: device?.bsdName)
        let reader = ventoyVersionReader
        let volumeURL = info.url
        Self.ventoyVersionQueue.async { [weak self] in
            let result = reader.readVersion(volumeURL: volumeURL, expected: expected)
            Task { @MainActor [weak self] in
                self?.finishVentoyVersionRead(result, driveID: driveID, token: token)
            }
        }
        let cap = ventoyVersionReadCap
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(cap * 1_000_000_000))
            self?.abandonVentoyVersionRead(driveID: driveID, token: token)
        }
    }

    /// The read returned. Its hold ends whatever happened; the result lands
    /// only if it belongs to the current connect (an unplug, or an unplug and
    /// replug, during the read makes it stale, and so does the cap).
    func finishVentoyVersionRead(_ result: VentoyProbeResult, driveID: UUID, token: UUID) {
        ventoyProbes[token] = nil
        if let leftover = result.leftoverMount { ventoyLeftoverMounts.insert(leftover) }
        guard ventoyVersionReads[driveID] == token else { return }
        ventoyVersionReads[driveID] = nil
        guard let drive = drive(id: driveID), isConnected(drive) else { return }
        ventoyVersions[driveID] = result.reading
    }

    /// The cap passed with the read still running: stop holding the device,
    /// so Eject and the pipeline are not held up any longer. The read stays
    /// in `ventoyProbes` (no longer holding) until it returns, so a quit
    /// still waits for it and no second read starts next to it.
    func abandonVentoyVersionRead(driveID: UUID, token: UUID) {
        guard ventoyProbes[token]?.holdsDevice == true else { return }
        ventoyProbes[token]?.holdsDevice = false
        guard ventoyVersionReads[driveID] == token else { return }
        ventoyVersionReads[driveID] = nil
        if let drive = drive(id: driveID), isConnected(drive) {
            ventoyVersions[driveID] = .unknown("Reading the Ventoy version took too long")
        }
    }

    /// Forget the reading when the drive goes away, so the next connect reads
    /// again (the stick may have had Ventoy upgraded elsewhere). A read still
    /// running keeps its entry in `ventoyProbes` until it returns.
    func forgetVentoyVersion(driveID: UUID) {
        ventoyVersions[driveID] = nil
        ventoyVersionReads[driveID] = nil
    }

    /// Nothing is mounted next to a drive that is being written: not while
    /// this drive has an update or copy in flight, and not while any flash
    /// runs, since a flash names a device rather than this registration.
    func blocksVentoyVersionRead(_ drive: ManagedDrive) -> Bool {
        if hasOperationsInFlight(drive) { return true }
        return drivesWithOperationsInFlight.contains { self.drive(id: $0)?.isFlashed == true }
    }

    // MARK: Cleanup

    /// At launch: undo any temporary VTOYEFI mount an earlier run left behind
    /// (a crash, a force quit). Runs on the read queue, ahead of any read.
    func cleanUpLeftoverVentoyMounts() {
        guard let janitor = ventoyMountJanitor else { return }
        Self.ventoyVersionQueue.async { [weak self] in
            let failed = janitor.cleanUpLeftovers()
            Task { @MainActor [weak self] in
                self?.ventoyLeftoverMounts.formUnion(failed)
            }
        }
    }

    /// At quit: wait a little for reads still running, then try once more to
    /// undo mounts that could not be undone. Bounded by `timeout` in total.
    func drainVentoyVersionReads(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !ventoyProbes.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let janitor = ventoyMountJanitor, !ventoyLeftoverMounts.isEmpty else { return }
        let leftovers = Array(ventoyLeftoverMounts)
        let remaining = max(0, deadline.timeIntervalSinceNow)
        let failed = await Self.runBounded(timeout: remaining) {
            leftovers.filter { !janitor.cleanUp($0) }
        }
        ventoyLeftoverMounts = Set(failed ?? leftovers)
    }

    /// Runs blocking `work` on a global queue and returns its result, or nil
    /// if it has not finished within `timeout` (the work carries on alone).
    nonisolated static func runBounded<T: Sendable>(timeout: TimeInterval,
                                                    _ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .utility).async { once.resume(work()) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
    }
}

/// Resumes a continuation exactly once, from whichever side gets there first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func resume(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
