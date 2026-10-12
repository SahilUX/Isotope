import Foundation
import IsotopeCore

extension AppStore {
    func importLocalFiles(_ urls: [URL]) throws {
        let files = try urls.map { try LocalFile(url: $0) }
        for file in files where !localFiles.contains(where: { $0.url == file.url }) {
            localFiles.append(file)
        }
    }

    func copyLocalFile(_ file: LocalFile, to driveID: UUID) throws {
        guard let drive = drive(id: driveID), !drive.isFlashed, isConnected(drive),
              let engine = updateEngine else { throw LocalFileError.unavailableDrive }
        guard !hasOperationsInFlight(drive) else { throw LocalFileError.busy }
        let current = try LocalFile(url: file.url)
        // An unassigned request copies without replacing a tracked image.
        let request = UpdateRequest(driveID: drive.id, driveName: drive.displayName,
                                    assignmentID: UUID(), entryID: "local-file", channelID: "local",
                                    title: current.name, release: current.release, isLocalFile: true)
        Task { await engine.enqueueManual(request, sourceFile: current.url, fileName: current.name) }
    }

    var localFlashDevices: [FlashDevice] {
        attachedDevices.filter { device in
            device.isEligibleForRegistration && device.hardwareID != nil
                && !drives.contains {
                    !$0.isFlashed && (device.volumeUUIDs.contains($0.volumeUUID)
                        || DeviceEnumerator.device(matching: $0, in: [device]) != nil)
                }
        }
    }

    func localFlashTargetIsCurrent(driveID: UUID, bsdName: String) -> Bool {
        guard let drive = drive(id: driveID), let device = attachedDevice(for: drive) else { return false }
        return device.bsdName == bsdName
    }

    func localFlashSourceIsSafe(_ source: URL, bsdName: String) -> Bool {
        guard let device = attachedDevices.first(where: { $0.bsdName == bsdName }) else { return false }
        let uuid = try? source.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        return !device.volumeUUIDs.contains(uuid ?? "")
            && !device.volumeMountPoints.contains { LocalFile.isInside(source, volume: $0) }
    }

    func localFlashPlan(_ file: LocalFile, device: FlashDevice) throws -> FlashPlan {
        let current = try LocalFile(url: file.url)
        guard current.canFlash, localFlashDevices.contains(device), flashEngine != nil else {
            throw LocalFileError.unavailableDrive
        }
        guard localFlashSourceIsSafe(current.url, bsdName: device.bsdName) else {
            throw LocalFileError.sourceOnDestination
        }
        let drive = drives.first { DeviceEnumerator.device(matching: $0, in: [device]) != nil }
        if let drive, hasOperationsInFlight(drive) { throw LocalFileError.busy }
        return FlashPlan(driveID: drive?.id ?? UUID(), driveName: drive?.displayName ?? device.displayName,
                         assignmentID: UUID(), entryID: "local-file", channelID: "local",
                         title: current.name, release: current.release, device: device,
                         fromVersion: drive?.singleAssignment?.installed?.displayVersion,
                         toVersion: "Local file", fileName: current.name, isoSizeBytes: current.sizeBytes,
                         isVerifiable: false,
                         gateFailure: FlashSafetyGate.evaluate(device: device.gateDescription(),
                                                               isoSizeBytes: current.sizeBytes),
                         localFile: current.url)
    }

    func startLocalFlash(_ plan: FlashPlan, verify: Bool) throws {
        guard let source = plan.localFile,
              let device = localFlashDevices.first(where: { $0.bsdName == plan.device.bsdName }),
              device.hardwareID == plan.device.hardwareID, plan.canFlash, flashEngine != nil else {
            throw LocalFileError.unavailableDrive
        }
        guard localFlashSourceIsSafe(source, bsdName: device.bsdName) else {
            throw LocalFileError.sourceOnDestination
        }
        var confirmed = plan
        if let drive = drive(id: plan.driveID) {
            guard !hasOperationsInFlight(drive) else { throw LocalFileError.busy }
        } else {
            let drive = try registerFlashedDrive(device: device, entryID: plan.entryID, channelID: plan.channelID)
            confirmed.driveID = drive.id
        }
        startFlash(confirmed, verify: verify)
    }
}
