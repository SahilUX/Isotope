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
///
/// The janitor reserves a disk the same way while it unmounts a leftover
/// (`isCleanup`). A cleanup reservation also holds off updates, copies, flashes,
/// deletes and ejects on that whole disk, as a running read does.
struct VentoyEjectReservation: Equatable, Sendable {
    var wholeDisk: String?
    var volumeUUIDs: Set<String>
    var isCleanup = false
}

/// A mount Isotope could not prove undone, and the physical device it is on
/// (PRD F74, DESIGN §21). It is keyed to the whole disk, not to a
/// registration: unregistering the drive does not release it.
struct VentoyStuckHold: Equatable, Sendable {
    /// The whole disk the mount is on, or nil when it was not listed (then
    /// every flashed drive is held, and the registration decides the release).
    var wholeDisk: String?
    /// The registration whose read left the mount; nil for one found at launch.
    var driveID: UUID?
    var volumeUUID: String
    /// Consecutive device scans that did not list `wholeDisk`.
    var missedScans = 0

    init(wholeDisk: String?, driveID: UUID?, volumeUUID: String) {
        self.wholeDisk = wholeDisk
        self.driveID = driveID
        self.volumeUUID = volumeUUID
    }

    init(_ probe: VentoyProbeHold) {
        self.init(wholeDisk: probe.wholeDisk, driveID: probe.driveID, volumeUUID: probe.volumeUUID)
    }

    /// Two consecutive scans without the disk confirm it was unplugged.
    static let scansToConfirmRemoval = 2
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
    static let ventoyReadStuck = "Isotope is still reading this drive's Ventoy version. Try again in a few minutes, or unplug and reconnect the drive."

    /// Why an update, copy, flash or delete is refused while a read's mount may
    /// still be there (it could not be unmounted, or its mount tool would not
    /// stop). Eject stays allowed.
    static let ventoyReadUnfinished = "Isotope couldn't finish reading the Ventoy version on this drive. Unplug and reconnect it, or quit and reopen Isotope."

    /// What a wait for the Ventoy reads ended in.
    enum VentoyReadWait: Equatable, Sendable {
        /// Nothing holds the device.
        case clear
        /// A read outlived `ventoyVersionWaitLimit`.
        case timedOut
        /// An earlier read left a mount that may still be there.
        case unfinished
        /// The operation was cancelled while it waited.
        case cancelled
    }

    /// What to show for a drive: nil while connected but not read yet (or not
    /// connected at all).
    func ventoyVersion(for drive: ManagedDrive) -> VentoyVersionReading? {
        guard !drive.isFlashed, isConnected(drive) else { return nil }
        return ventoyVersions[drive.id]
    }

    /// True while a read holds this drive's physical device: the same
    /// registration, the same volume, or the same whole disk (a stick can be
    /// registered as a Ventoy drive and as a flashed drive at once).
    /// The janitor unmounting a leftover on this drive's disk counts the same.
    func isReadingVentoyVersion(_ drive: ManagedDrive) -> Bool {
        let disk = physicalDisk(of: drive)
        return ventoyProbes.values.contains { Self.hold($0, covers: drive, disk: disk) }
            || isVentoyCleanupReserved(disk: disk)
    }

    /// True while a read holds the whole disk `bsdName` (or a disk it could
    /// not name, which might be this one), or the janitor is unmounting on it.
    func isReadingVentoyVersion(bsdName: String) -> Bool {
        ventoyProbes.values.contains { $0.wholeDisk == nil || $0.wholeDisk == bsdName }
            || isVentoyCleanupReserved(disk: bsdName)
    }

    private func isVentoyCleanupReserved(disk: String?) -> Bool {
        guard let disk else { return false }
        return ventoyEjectReservations.values.contains { $0.isCleanup && $0.wholeDisk == disk }
    }

    /// True while an earlier read left a mount on this drive's physical device
    /// that may still be there (see `ventoyReadUnfinished`). Unlike an active
    /// read this does not block an eject.
    func isVentoyReadUnfinished(_ drive: ManagedDrive) -> Bool {
        let disk = physicalDisk(of: drive)
        return ventoyStuckHolds.values.contains { Self.stuck($0, covers: drive, disk: disk) }
    }

    func isVentoyReadUnfinished(bsdName: String) -> Bool {
        ventoyStuckHolds.values.contains { $0.wholeDisk == nil || $0.wholeDisk == bsdName }
    }

    private static func hold(_ hold: VentoyProbeHold, covers drive: ManagedDrive, disk: String?) -> Bool {
        if hold.driveID == drive.id { return true }
        if !drive.volumeUUID.isEmpty, hold.volumeUUID == drive.volumeUUID { return true }
        if let disk, disk == hold.wholeDisk { return true }
        // A read whose disk is unknown might be on any flashed stick.
        return drive.isFlashed && hold.wholeDisk == nil
    }

    private static func stuck(_ hold: VentoyStuckHold, covers drive: ManagedDrive, disk: String?) -> Bool {
        if hold.driveID == drive.id { return true }
        if !drive.volumeUUID.isEmpty, hold.volumeUUID == drive.volumeUUID { return true }
        if let disk, disk == hold.wholeDisk { return true }
        // A mount whose disk is unknown might be on any flashed stick.
        return drive.isFlashed && hold.wholeDisk == nil
    }

    /// Drops the holds whose whole disk is not known and whose drive is no
    /// longer connected. A hold on a known disk is never released here: it
    /// outlives the registration and the volume's connection, and goes only
    /// when the disk is confirmed removed (`noteDeviceScanForVentoyHolds`) or
    /// the mount is cleaned up.
    func releaseStuckVentoyHolds() {
        guard !ventoyStuckHolds.isEmpty else { return }
        ventoyStuckHolds = ventoyStuckHolds.filter { _, hold in
            guard hold.wholeDisk == nil else { return true }
            guard let id = hold.driveID, let drive = drive(id: id), isConnected(drive) else { return false }
            return true
        }
    }

    /// Called for every device scan. A hold on a known disk is released when
    /// that disk is missing from `VentoyStuckHold.scansToConfirmRemoval`
    /// consecutive scans, so one scan that comes back empty or short for a
    /// moment (a transient result) never releases it. A scan that lists the
    /// disk again starts the count over. The first missing scan asks the
    /// watcher for another one, so a real unplug is confirmed without waiting
    /// for the next attach or detach event.
    func noteDeviceScanForVentoyHolds() {
        guard !ventoyStuckHolds.isEmpty else { return }
        var awaitingConfirmation = false
        for (container, hold) in ventoyStuckHolds {
            guard let disk = hold.wholeDisk else { continue }
            var updated = hold
            if attachedDevices.contains(where: { $0.bsdName == disk }) {
                updated.missedScans = 0
            } else {
                updated.missedScans += 1
            }
            if updated.missedScans >= VentoyStuckHold.scansToConfirmRemoval {
                ventoyStuckHolds[container] = nil
            } else {
                ventoyStuckHolds[container] = updated
                if updated.missedScans > 0 { awaitingConfirmation = true }
            }
        }
        releaseStuckVentoyHolds()
        if awaitingConfirmation { scheduleDeviceRecheck() }
    }

    private func scheduleDeviceRecheck() {
        guard let rescan = rescanDevices, !ventoyRecheckPending else { return }
        ventoyRecheckPending = true
        let delay = ventoyRemovalRecheckDelay
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            self?.ventoyRecheckPending = false
            rescan()
        }
    }

    /// Records a mount that may still be there and the device it holds.
    func holdVentoyMount(_ container: URL, _ hold: VentoyStuckHold) {
        ventoyLeftoverMounts.insert(container)
        // The count starts at 0 even when the disk is not in the device list
        // yet (a read scheduled at launch can finish before the first scan
        // fills it): only scans taken after the hold count as missing.
        ventoyStuckHolds[container] = ventoyStuckHolds[container] ?? hold
        releaseStuckVentoyHolds()
        if let disk = ventoyStuckHolds[container]?.wholeDisk,
           !attachedDevices.contains(where: { $0.bsdName == disk }) {
            scheduleDeviceRecheck()
        }
    }

    /// The whole disk a drive is attached at right now, from the device list.
    func physicalDisk(of drive: ManagedDrive) -> String? {
        if drive.isFlashed { return attachedDevice(for: drive)?.bsdName }
        return attachedDevices.first { $0.volumeUUIDs.contains(drive.volumeUUID) }?.bsdName
    }

    /// Called by `UpdateEngine` and `FlashEngine` just before an operation
    /// starts. `.clear` once no read holds the drive or `bsdName`;
    /// `.unfinished` at once when an earlier read left a mount that may still
    /// be there; `.timedOut` if a read still holds it after
    /// `ventoyVersionWaitLimit`; `.cancelled` as soon as `isCancelled` says so,
    /// checked on every poll. The caller refuses the operation in the last
    /// three cases, with nothing changed.
    func waitForVentoyVersionReads(driveID: UUID, bsdName: String? = nil,
                                   isCancelled: @Sendable () -> Bool = { false }) async -> VentoyReadWait {
        let deadline = Date().addingTimeInterval(ventoyVersionWaitLimit)
        while true {
            if isCancelled() { return .cancelled }
            let drive = drive(id: driveID)
            if drive.map(isVentoyReadUnfinished) == true
                || bsdName.map({ isVentoyReadUnfinished(bsdName: $0) }) == true { return .unfinished }
            let held = drive.map(isReadingVentoyVersion) == true
                || bsdName.map { isReadingVentoyVersion(bsdName: $0) } == true
            guard held else { return .clear }
            guard Date() < deadline else { return .timedOut }
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
        let hold = ventoyProbes[token]
        ventoyProbes[token] = nil
        ventoyReadTickets[token] = nil
        if let leftover = result.leftoverMount {
            // The mount may still be there (it could not be unmounted, or its
            // tool was abandoned and may yet complete): keep the device held
            // until its disk is unplugged, the app quits or it is cleaned up.
            //
            // The disk comes from the reader, which identified and verified it
            // itself: the read may have been scheduled before the device list
            // knew the drive (`hold.wholeDisk == nil`), and a hold keyed to the
            // registration would then vanish with an unregister while the mount
            // is still on the disk. Only a read that never identified a disk
            // keeps the registration-keyed hold.
            let disk = result.wholeDisk ?? hold?.wholeDisk
            if var stuck = hold.map(VentoyStuckHold.init) {
                stuck.wholeDisk = disk
                holdVentoyMount(leftover, stuck)
            } else if let disk {
                holdVentoyMount(leftover, VentoyStuckHold(wholeDisk: disk, driveID: nil, volumeUUID: ""))
            } else {
                ventoyLeftoverMounts.insert(leftover)
            }
        }
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
        releaseStuckVentoyHolds()
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
    func reserveForEject(wholeDisk: String?, volumeUUIDs: Set<String>, isCleanup: Bool = false) -> UUID {
        let id = UUID()
        ventoyEjectReservations[id] = VentoyEjectReservation(wholeDisk: wholeDisk,
                                                             volumeUUIDs: volumeUUIDs.filter { !$0.isEmpty },
                                                             isCleanup: isCleanup)
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
    /// (a crash, a force quit). Runs on the read queue, ahead of any read. A
    /// mount it cannot undo holds its whole disk, as one a read left does.
    func cleanUpLeftoverVentoyMounts() {
        guard var janitor = ventoyMountJanitor else { return }
        janitor.diskGate = ventoyCleanupGate()
        Self.ventoyVersionQueue.async { [weak self] in
            let failures = janitor.cleanUpAll()
            Task { @MainActor [weak self] in
                self?.recordFailedVentoyCleanups(failures)
            }
        }
    }

    /// Each failed cleanup goes into `ventoyLeftoverMounts`, and, when the
    /// janitor identified the whole disk the mount is on, holds that disk
    /// until the cleanup succeeds or the device is unplugged.
    func recordFailedVentoyCleanups(_ failures: [VentoyCleanupFailure]) {
        for failure in failures {
            if let disk = failure.wholeDisk {
                holdVentoyMount(failure.container, VentoyStuckHold(wholeDisk: disk, driveID: nil, volumeUUID: ""))
            } else {
                ventoyLeftoverMounts.insert(failure.container)
            }
        }
    }

    /// The janitor's disk gate: before it unmounts a leftover it reserves that
    /// whole disk, as an eject does, and skips the mount while an operation,
    /// an eject or a read is on the disk. While the unmount runs, updates,
    /// copies, flashes, deletes and ejects on that disk wait or are refused.
    /// Called from the janitor's thread; nothing on the main actor waits on
    /// that thread, so the hop cannot deadlock.
    ///
    /// The release says whether the unmount worked. On failure the hold is
    /// recorded in the same main-actor step that ends the reservation, so the
    /// disk is never unguarded in between.
    nonisolated func ventoyCleanupGate() -> VentoyMountJanitor.DiskGate {
        { [weak self] container, disk in
            let reservation: UUID? = DispatchQueue.main.sync {
                MainActor.assumeIsolated { self?.reserveDiskForVentoyCleanup(disk) }
            }
            guard let reservation else { return nil }
            return { cleaned in
                Task { @MainActor [weak self] in
                    self?.finishVentoyCleanup(reservation, container: container, wholeDisk: disk, cleaned: cleaned)
                }
            }
        }
    }

    func finishVentoyCleanup(_ reservation: UUID, container: URL, wholeDisk: String, cleaned: Bool) {
        if cleaned {
            ventoyStuckHolds[container] = nil
            ventoyLeftoverMounts.remove(container)
        } else {
            holdVentoyMount(container, VentoyStuckHold(wholeDisk: wholeDisk, driveID: nil, volumeUUID: ""))
        }
        releaseEjectReservation(reservation)
    }

    /// Reserves `disk` for the janitor, or nil when anything is on it: an
    /// update, copy or flash in flight (a drive whose disk is unknown might be
    /// this one), an eject, a read or another cleanup.
    func reserveDiskForVentoyCleanup(_ disk: String) -> UUID? {
        guard !ventoyEjectReservations.values.contains(where: { $0.wholeDisk == disk }),
              !isReadingVentoyVersion(bsdName: disk) else { return nil }
        for id in drivesWithOperationsInFlight {
            guard let drive = drive(id: id) else { continue }
            guard let onDisk = physicalDisk(of: drive), onDisk != disk else { return nil }
        }
        let volumes = attachedDevices.first { $0.bsdName == disk }?.volumeUUIDs ?? []
        return reserveForEject(wholeDisk: disk, volumeUUIDs: Set(volumes), isCleanup: true)
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
        guard var janitor = ventoyMountJanitor, !ventoyLeftoverMounts.isEmpty else { return }
        janitor.diskGate = ventoyCleanupGate()
        let cleaner = janitor
        let leftovers = Array(ventoyLeftoverMounts)
        let remaining = max(0, deadline.timeIntervalSinceNow)
        guard let failures = await Self.runBounded(timeout: remaining, {
            leftovers.compactMap { cleaner.attemptCleanUp($0) }
        }) else { return }   // out of time: every mount stays recorded and held
        let failed = Set(failures.map(\.container))
        ventoyLeftoverMounts = failed
        // A mount the janitor undid no longer holds its device.
        ventoyStuckHolds = ventoyStuckHolds.filter { failed.contains($0.key) }
        recordFailedVentoyCleanups(failures)
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
