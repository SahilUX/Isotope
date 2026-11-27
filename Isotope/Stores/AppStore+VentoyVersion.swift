import Foundation
import IsotopeCore

/// One VTOYEFI read that is queued or running (PRD F74). While it is in
/// `ventoyProbes`, no flash, update, copy, delete or eject touches that
/// physical device.
struct VentoyProbeHold: Equatable, Sendable {
    var driveID: UUID
    var volumeUUID: String
    /// The whole disk the device list had the drive on, or nil when it was not
    /// listed (then every flash waits for the read).
    var wholeDisk: String?
}

/// An eject in progress (PRD F74): no read is scheduled or started for that
/// whole disk, or those volumes, until it completes or fails.
struct VentoyEjectReservation: Equatable, Sendable {
    var wholeDisk: String?
    var volumeUUIDs: Set<String>
}

/// PRD F74: the Ventoy release on each connected Ventoy drive.
///
/// Read once per connect, on a dedicated serial queue, and kept in memory
/// only: it is not written to `drives.json`, so no on-disk format changes. The
/// exclusion runs both ways: a read does not start while the drive (or any
/// flash, or an eject of its disk) is busy, and while a read holds a physical
/// device, nothing that writes to, deletes from or ejects that device starts
/// (the engines wait, Delete and Eject refuse).
///
/// Each read carries a `VentoyReadTicket`. The cap (`ventoyVersionReadCap`)
/// cancels it: a read still queued then never starts and its hold goes at
/// once; a read already running keeps its hold until it has returned and
/// unmounted, which `VentoyVersionReader.activeReadBound` bounds. An
/// operation that waits longer than `ventoyVersionWaitLimit` is refused
/// rather than started next to a read that may still have a mount.
extension AppStore {
    /// Where every read runs: blocking waits on `mount`/`umount` stay off the
    /// main actor and off Swift's shared task threads, and two reads never
    /// overlap.
    nonisolated static let ventoyVersionQueue = DispatchQueue(label: "Isotope.VentoyVersion", qos: .utility)

    /// Why an update, copy or flash is refused when a read outlives its bound.
    static let ventoyReadStuck = "Isotope is still reading this drive's Ventoy version, so nothing was changed. Try again in a few minutes, or unplug and reconnect the drive."

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
        ventoyProbes.values.contains { $0.wholeDisk == nil || $0.wholeDisk == bsdName }
    }

    /// The whole disk a drive is attached at right now, from the device list.
    func physicalDisk(of drive: ManagedDrive) -> String? {
        if drive.isFlashed { return attachedDevice(for: drive)?.bsdName }
        return attachedDevices.first { $0.volumeUUIDs.contains(drive.volumeUUID) }?.bsdName
    }

    /// Called by `UpdateEngine` and `FlashEngine` just before an operation
    /// starts: true once no read holds the drive or `bsdName`; false if one
    /// still does after `ventoyVersionWaitLimit`, and the caller then refuses
    /// the operation with `ventoyReadStuck`.
    func waitForVentoyVersionReads(driveID: UUID, bsdName: String? = nil) async -> Bool {
        let deadline = Date().addingTimeInterval(ventoyVersionWaitLimit)
        while true {
            let drive = drive(id: driveID)
            let held = drive.map(isReadingVentoyVersion) == true
                || bsdName.map { isReadingVentoyVersion(bsdName: $0) } == true
            guard held else { return true }
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Starts the read for a connected Ventoy drive unless this connect has
    /// already been read, a read for it is queued or running, or the drive is
    /// busy. Called after every scan; almost every call does nothing.
    func refreshVentoyVersion(driveID: UUID) {
        guard ventoyVersionReader.isEnabled, let drive = drive(id: driveID), !drive.isFlashed,
              let info = volumeInfo(for: drive),
              ventoyVersions[driveID] == nil, ventoyVersionReads[driveID] == nil,
              !ventoyProbes.values.contains(where: { $0.driveID == driveID }),
              !blocksVentoyVersionRead(drive)
        else { return }
        let token = UUID()
        let ticket = VentoyReadTicket()
        let device = attachedDevices.first { $0.volumeUUIDs.contains(drive.volumeUUID) }
        let expected = VentoyExpectedIdentity(volumeUUID: drive.volumeUUID, wholeDisk: device?.bsdName,
                                              hardwareID: device?.hardwareID)
        ventoyVersionReads[driveID] = token
        ventoyProbes[token] = VentoyProbeHold(driveID: driveID, volumeUUID: drive.volumeUUID,
                                              wholeDisk: device?.bsdName)
        ventoyReadTickets[token] = ticket
        let reader = ventoyVersionReader
        let volumeURL = info.url
        Self.ventoyVersionQueue.async { [weak self] in
            // The work has left the queue: check again on the main actor, where
            // the cap, unplugs and the pipeline change state, before anything
            // is described or mounted. Nothing on the main actor ever waits
            // synchronously on this queue, so this cannot deadlock.
            let started = DispatchQueue.main.sync {
                MainActor.assumeIsolated { self?.startVentoyVersionRead(token: token) ?? false }
            }
            let result = started
                ? reader.readVersion(volumeURL: volumeURL, expected: expected, ticket: ticket)
                : VentoyProbeResult(.unknown(VentoyReadTicket.cancelledReason))
            ticket.finish()
            Task { @MainActor [weak self] in
                self?.finishVentoyVersionRead(result, driveID: driveID, token: token)
            }
        }
        let cap = ventoyVersionReadCap
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(cap * 1_000_000_000))
            self?.expireVentoyVersionRead(driveID: driveID, token: token)
        }
    }

    /// The start check, on the main actor as the work leaves the queue: the
    /// read is still wanted (not cancelled by the cap, an unplug or an
    /// unregister) and nothing is writing to or ejecting the drive. If not,
    /// the ticket is cancelled and the hold released here, and the read
    /// never describes or mounts anything.
    func startVentoyVersionRead(token: UUID) -> Bool {
        guard let ticket = ventoyReadTickets[token] else { return false }
        if let hold = ventoyProbes[token], ventoyVersionReads[hold.driveID] == token,
           let drive = drive(id: hold.driveID), isConnected(drive), !blocksVentoyVersionRead(drive),
           ticket.activate() {
            return true
        }
        ticket.cancel()
        if let hold = ventoyProbes[token], ventoyVersionReads[hold.driveID] == token {
            // Not read this time; a later scan or the pipeline letting go retries.
            ventoyVersionReads[hold.driveID] = nil
        }
        ventoyProbes[token] = nil
        ventoyReadTickets[token] = nil
        return false
    }

    /// The read returned and cleaned up: its hold ends. The result lands only
    /// if it belongs to the current connect (an unplug, or an unplug and
    /// replug, during the read makes it stale, and so does the cap).
    func finishVentoyVersionRead(_ result: VentoyProbeResult, driveID: UUID, token: UUID) {
        ventoyProbes[token] = nil
        ventoyReadTickets[token] = nil
        if let leftover = result.leftoverMount { ventoyLeftoverMounts.insert(leftover) }
        guard ventoyVersionReads[driveID] == token else { return }
        ventoyVersionReads[driveID] = nil
        guard let drive = drive(id: driveID), isConnected(drive) else { return }
        ventoyVersions[driveID] = result.reading
    }

    /// The cap passed before the read returned. Its ticket is cancelled: a
    /// read still queued will never start, so its hold goes now; a read
    /// already running stops before its next mount attempt, and keeps its
    /// hold until it has returned and unmounted.
    func expireVentoyVersionRead(driveID: UUID, token: UUID) {
        guard let ticket = ventoyReadTickets[token] else { return }
        if ventoyVersionReads[driveID] == token {
            ventoyVersionReads[driveID] = nil
            if let drive = drive(id: driveID), isConnected(drive) {
                ventoyVersions[driveID] = .unknown("Reading the Ventoy version took too long")
            }
        }
        if ticket.cancel() {
            ventoyProbes[token] = nil
            ventoyReadTickets[token] = nil
        }
    }

    /// Forget the reading when the drive goes away, so the next connect reads
    /// again (the stick may have had Ventoy upgraded elsewhere). A queued read
    /// for it is cancelled and released; a running one is asked to stop and
    /// keeps its hold until it returns.
    func forgetVentoyVersion(driveID: UUID) {
        ventoyVersions[driveID] = nil
        ventoyVersionReads[driveID] = nil
        for (token, hold) in ventoyProbes where hold.driveID == driveID {
            guard let ticket = ventoyReadTickets[token] else { continue }
            if ticket.cancel() {
                ventoyProbes[token] = nil
                ventoyReadTickets[token] = nil
            }
        }
    }

    /// Nothing is mounted next to a drive that is being written or ejected:
    /// not while this drive has an update or copy in flight, not while any
    /// flash runs (a flash names a device rather than this registration), and
    /// not while an eject of its disk is under way.
    func blocksVentoyVersionRead(_ drive: ManagedDrive) -> Bool {
        if hasOperationsInFlight(drive) { return true }
        if isEjectReserved(drive) { return true }
        return drivesWithOperationsInFlight.contains { self.drive(id: $0)?.isFlashed == true }
    }

    // MARK: Eject reservations

    /// Holds off reads of a disk (and its volumes) while an eject runs.
    func reserveForEject(wholeDisk: String?, volumeUUIDs: Set<String>) -> UUID {
        let id = UUID()
        ventoyEjectReservations[id] = VentoyEjectReservation(wholeDisk: wholeDisk,
                                                             volumeUUIDs: volumeUUIDs.filter { !$0.isEmpty })
        return id
    }

    func releaseEjectReservation(_ id: UUID) {
        ventoyEjectReservations[id] = nil
    }

    func isEjectReserved(_ drive: ManagedDrive) -> Bool {
        guard !ventoyEjectReservations.isEmpty else { return false }
        let disk = physicalDisk(of: drive)
        return ventoyEjectReservations.values.contains { reservation in
            if !drive.volumeUUID.isEmpty, reservation.volumeUUIDs.contains(drive.volumeUUID) { return true }
            if let disk, disk == reservation.wholeDisk { return true }
            return false
        }
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

    /// At quit: cancel every read (a queued one then never starts, a running
    /// one stops before its next mount attempt), wait a little for those
    /// still running, then try once more to undo mounts that could not be
    /// undone. Bounded by `timeout` in total.
    func drainVentoyVersionReads(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        for (token, ticket) in ventoyReadTickets where ticket.cancel() {
            ventoyProbes[token] = nil
            ventoyReadTickets[token] = nil
        }
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
