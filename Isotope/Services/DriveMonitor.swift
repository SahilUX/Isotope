import AppKit
import Foundation
import IsotopeCore

/// Watches volumes mount and unmount and keeps `AppStore`'s drive state honest
/// (DESIGN §4.3, PRD F3/F4/F7).
///
/// `NSWorkspace`'s notification centre delivers mount/unmount on the main queue,
/// which is also where `AppStore` lives, so no hopping is needed for the state
/// updates; only the catalog check on mount is asynchronous.
@Observable
@MainActor
final class DriveMonitor {
    private unowned let store: AppStore
    private var observers: [NSObjectProtocol] = []
    private var mountTasks: [UUID: Task<Void, Never>] = [:]
    /// PRD F27: flashed drives are watched as *devices*, not volumes.
    private let devices = DeviceEnumerator()
    /// Flashed drives seen attached on the previous device sweep, so an attach
    /// fires the F16 notification exactly once per plug-in.
    private var attachedDriveIDs: Set<UUID> = []

    /// DESIGN §4.3: on mount, only re-check a drive's entries if the cached
    /// releases are older than this.
    var releaseCacheMaxAge: TimeInterval = 6 * 60 * 60

    /// Called once the mount sequence has fully settled — after the scan *and*
    /// after the targeted catalog check, so observers see post-check staleness.
    var onDriveMounted: ((ManagedDrive, ReconcileResult?) -> Void)?

    init(store: AppStore) {
        self.store = store
    }

    // No `deinit` teardown: the observers are main-actor state and the monitor
    // lives for the whole app session. `stop()` is the explicit exit.

    // MARK: - Lifecycle

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.didMountNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let url = Self.volumeURL(from: note) else { return }
                MainActor.assumeIsolated { self?.volumeDidMount(at: url) }
            },
            center.addObserver(forName: NSWorkspace.didUnmountNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let url = Self.volumeURL(from: note) else { return }
                MainActor.assumeIsolated { self?.volumeDidUnmount(at: url) }
            },
        ]
        enumerateMountedVolumes()
        // DiskArbitration attach/detach: a flashed drive has no mounted volume
        // to key on, so `NSWorkspace`'s mount notifications never see it.
        devices.start { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        refreshDevices()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers = []
        for task in mountTasks.values { task.cancel() }
        mountTasks = [:]
        devices.stop()
    }

    nonisolated private static func volumeURL(from note: Notification) -> URL? {
        note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
    }

    // MARK: - Enumeration & events

    /// Initial pass at launch: whatever is already mounted counts as a mount.
    func enumerateMountedVolumes() {
        let mounted = DriveAccess.mountedVolumes()
        let byUUID = Dictionary(mounted.compactMap { info in
            info.volumeUUID.map { ($0, info) }
        }, uniquingKeysWith: { first, _ in first })

        // Flashed drives are handled by `refreshDevices()`: their volume UUID is
        // a display detail, and they are often not mounted at all (PRD F27).
        for drive in store.drives where !drive.isFlashed {
            if let info = byUUID[drive.volumeUUID] {
                connect(drive: drive, info: info)
            } else {
                store.markDisconnected(volumeUUID: drive.volumeUUID)
                checkForReplacedVolume(drive: drive, mounted: mounted)
            }
        }
    }

    private func volumeDidMount(at url: URL) {
        guard let info = try? DriveAccess.volumeInfo(at: url) else { return }
        if let uuid = info.volumeUUID,
           let drive = store.drives.first(where: { !$0.isFlashed && $0.volumeUUID == uuid }) {
            connect(drive: drive, info: info)
            return
        }
        // Not a known UUID: it may still be the volume a registration points at,
        // i.e. a reformatted stick (PRD F4).
        for drive in store.drives where !drive.isFlashed && !store.isConnected(drive) {
            checkForReplacedVolume(drive: drive, mounted: [info])
        }
    }

    private func volumeDidUnmount(at url: URL) {
        let affected = store.connectedVolumes.filter { $0.value.url == url }
        for (uuid, _) in affected {
            store.markDisconnected(volumeUUID: uuid)
        }
        // The mount point may be gone before we can read the UUID back, so also
        // drop any drive whose bookmark resolves to this path.
        for drive in store.drives where !drive.isFlashed && store.isConnected(drive) {
            guard let resolved = try? DriveAccess.resolveBookmark(drive.bookmark),
                  resolved.url.standardizedFileURL == url.standardizedFileURL else { continue }
            store.markDisconnected(volumeUUID: drive.volumeUUID)
        }
    }

    // MARK: - Mount handling

    private func connect(drive: ManagedDrive, info: VolumeInfo) {
        store.markConnected(drive, info: info)
        // DESIGN §6: `.part` leftovers from a copy that was cut short are
        // cleaned up the next time the drive shows up.
        cleanUpPartFiles(drive: drive)
        let result = store.scanAndReconcile(driveID: drive.id)

        // DESIGN §4.3: a targeted catalog check for this drive's entries, and
        // only when the cached releases have gone stale. Re-scan afterwards so
        // a newly-resolved filename can claim a file the first pass could not.
        let refreshed = store.drive(id: drive.id)
        let jobs = refreshed.map { store.channelJobs(for: $0) } ?? []
        let needsCheck = refreshed.map { store.releaseCacheIsStale(for: $0, maxAge: releaseCacheMaxAge) } ?? false
        guard needsCheck, !jobs.isEmpty else {
            finishMount(driveID: drive.id, fallback: drive, result: result)
            return
        }
        mountTasks[drive.id]?.cancel()
        mountTasks[drive.id] = Task { [weak self] in
            guard let self else { return }
            await store.checkChannels(jobs)
            guard !Task.isCancelled else { return }
            var latest = result
            if let current = store.drive(id: drive.id), store.isConnected(current) {
                latest = store.scanAndReconcile(driveID: drive.id) ?? result
            }
            mountTasks[drive.id] = nil
            // PRD F16: the notification has to reflect *post-check* staleness,
            // so the mount hook fires here rather than before the check —
            // otherwise a drive that just went stale announces nothing.
            finishMount(driveID: drive.id, fallback: drive, result: latest)
        }
    }

    /// End of the mount sequence: scan done, catalog check done. Anything that
    /// needs to know "is this drive up to date?" runs from here.
    private func finishMount(driveID: UUID, fallback: ManagedDrive, result: ReconcileResult?) {
        let drive = store.drive(id: driveID) ?? fallback
        guard store.isConnected(drive) else { return }
        onDriveMounted?(drive, result)
        store.announceUpdates(for: driveID)
    }

    private func cleanUpPartFiles(drive: ManagedDrive) {
        guard let resolved = try? DriveAccess.resolveBookmark(drive.bookmark) else { return }
        _ = try? DriveAccess.withAccess(to: resolved.url) { volume in
            PartFileCleanup.run(volume: volume, isoFolder: drive.isoFolder)
        }
    }

    /// PRD F4: the bookmark still resolves, but the volume sitting there has a
    /// different UUID — reformatted or replaced. Warn, never silently rebind.
    private func checkForReplacedVolume(drive: ManagedDrive, mounted: [VolumeInfo]) {
        guard let resolved = try? DriveAccess.resolveBookmark(drive.bookmark) else { return }
        let path = resolved.url.standardizedFileURL
        guard let occupant = mounted.first(where: { $0.url.standardizedFileURL == path }) else {
            // Nothing is mounted there: the drive is simply unplugged.
            if case .changed = store.driveIssues[drive.id] { store.setIssue(nil, for: drive.id) }
            return
        }
        guard occupant.volumeUUID != drive.volumeUUID else { return }
        store.setIssue(.changed(volumeName: occupant.name, foundUUID: occupant.volumeUUID),
                       for: drive.id)
    }

    // MARK: - Devices (PRD F27)

    /// Re-reads the attached USB devices and settles every flashed drive's
    /// connection state. Cheap enough to run on every attach/detach event.
    func refreshDevices() {
        store.attachedDevices = devices.devices()
        var attachedNow: Set<UUID> = []
        for drive in store.drives where drive.isFlashed {
            guard let device = store.attachedDevice(for: drive) else { continue }
            attachedNow.insert(drive.id)
            markFlashedDriveSeen(drive, device: device)
        }
        let newlyAttached = attachedNow.subtracting(attachedDriveIDs)
        attachedDriveIDs = attachedNow
        // PRD F16, unchanged semantics: check this drive's entries if the cache
        // has gone stale, then announce whatever is stale afterwards.
        for driveID in newlyAttached { announceFlashedDrive(driveID: driveID) }
    }

    private func markFlashedDriveSeen(_ drive: ManagedDrive, device: FlashDevice) {
        var updated = drive
        updated.lastSeenAt = Date()
        updated.lastBSDName = device.bsdName
        updated.capacityBytes = device.sizeBytes
        if !device.displayName.isEmpty { updated.displayName = device.displayName }
        if let uuid = device.volumeUUIDs.first { updated.volumeUUID = uuid }
        if updated != drive { store.updateDrive(updated) }
        // PRD F40/F44: the stick may have been re-flashed somewhere else since
        // we last saw it. Two pieces of evidence are available without
        // administrator rights — its volume labels, and (F44) a marker file read
        // read-only from whatever it has mounted. Together they tell "same
        // image, newer version" from "this is something else now", and they
        // answer for images whose label carries no version at all.
        store.reconcileFlashedContents(driveID: drive.id, labels: device.volumeNames,
                                       probedVersion: store.probedVersion(for: drive, device: device))
    }

    private func announceFlashedDrive(driveID: UUID) {
        guard let drive = store.drive(id: driveID) else { return }
        let jobs = store.channelJobs(for: drive)
        guard !jobs.isEmpty, store.releaseCacheIsStale(for: drive, maxAge: releaseCacheMaxAge) else {
            store.announceUpdates(for: driveID)
            return
        }
        mountTasks[driveID]?.cancel()
        mountTasks[driveID] = Task { [weak self] in
            guard let self else { return }
            await store.checkChannels(jobs)
            guard !Task.isCancelled else { return }
            mountTasks[driveID] = nil
            guard let current = store.drive(id: driveID), store.isConnected(current) else { return }
            onDriveMounted?(current, nil)
            store.announceUpdates(for: driveID)
        }
    }

    // MARK: - Manual rescan

    /// The Rescan button in DriveDetailView.
    func rescan(driveID: UUID) {
        guard let drive = store.drive(id: driveID) else { return }
        guard !drive.isFlashed else {
            refreshDevices()
            return
        }
        if let info = DriveAccess.volumeInfo(forVolumeUUID: drive.volumeUUID) {
            connect(drive: drive, info: info)
        } else {
            store.markDisconnected(volumeUUID: drive.volumeUUID)
            checkForReplacedVolume(drive: drive, mounted: DriveAccess.mountedVolumes())
        }
    }
}
