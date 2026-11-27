import Foundation
import IsotopeCore

/// PRD F74: the Ventoy release on each connected Ventoy drive.
///
/// Read once per connect, off the main actor, and kept in memory only: it is
/// not written to `drives.json`, so no on-disk format changes. A drive with an
/// update, copy or flash in flight is not read; the next scan after it settles
/// tries again.
extension AppStore {
    /// What to show for a drive: nil while connected but not read yet (or not
    /// connected at all).
    func ventoyVersion(for drive: ManagedDrive) -> VentoyVersionReading? {
        guard !drive.isFlashed, isConnected(drive) else { return nil }
        return ventoyVersions[drive.id]
    }

    func isReadingVentoyVersion(_ drive: ManagedDrive) -> Bool {
        ventoyVersionReads[drive.id] != nil
    }

    /// Starts the read for a connected Ventoy drive unless this connect has
    /// already been read, a read is running, or the drive is busy. Called
    /// after every scan; almost every call does nothing.
    func refreshVentoyVersion(driveID: UUID) {
        guard let drive = drive(id: driveID), !drive.isFlashed,
              let info = volumeInfo(for: drive),
              ventoyVersions[driveID] == nil, ventoyVersionReads[driveID] == nil,
              !blocksVentoyVersionRead(drive)
        else { return }
        let token = UUID()
        ventoyVersionReads[driveID] = token
        let reader = ventoyVersionReader
        let volumeURL = info.url
        Task { [weak self] in
            let reading = await Task.detached(priority: .utility) {
                reader.readVersion(volumeURL: volumeURL)
            }.value
            self?.finishVentoyVersionRead(reading, driveID: driveID, token: token)
        }
    }

    /// Lands a result only if it belongs to the current connect: an unplug,
    /// or an unplug and replug, during the read makes it stale.
    func finishVentoyVersionRead(_ reading: VentoyVersionReading, driveID: UUID, token: UUID) {
        guard ventoyVersionReads[driveID] == token else { return }
        ventoyVersionReads[driveID] = nil
        guard let drive = drive(id: driveID), isConnected(drive) else { return }
        ventoyVersions[driveID] = reading
    }

    /// Forget the reading when the drive goes away, so the next connect reads
    /// again (the stick may have had Ventoy upgraded elsewhere).
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
}
