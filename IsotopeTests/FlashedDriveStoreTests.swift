import IsotopeCore
import XCTest
@testable import Isotope

/// Registration, identity matching and the flash plan (PRD F26/F27/F28/F32) —
/// all offline: the "devices" are values, never real hardware.
@MainActor
final class FlashedDriveStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeFlashStoreTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() async -> AppStore {
        let store = AppStore(locations: StoreLocations(root: root), catalogResourceURL: nil)
        await store.loadAtLaunch()
        store.notifications = RecordingNotificationService()
        store.addCustomEntry(CatalogEntry(
            id: "arch", name: "Arch Linux", kind: .linux,
            channels: [Channel(id: "default", name: "Default",
                               provider: .staticURL(url: URL(string: "https://example.com/arch.iso")!,
                                                    checksumURL: nil))],
            isBuiltIn: false))
        store.addCustomEntry(CatalogEntry(
            id: "windows-11", name: "Windows 11", kind: .windows,
            channels: [Channel(id: "default", name: "Default",
                               provider: .windowsManual(infoURL: URL(string: "https://example.com/i")!,
                                                        downloadPage: URL(string: "https://example.com/d")!))],
            isBuiltIn: false))
        return store
    }

    private func device(bsdName: String = "disk4", serial: String? = "SERIAL-1",
                        sizeBytes: Int64 = 32 << 30, isBootDisk: Bool = false) -> FlashDevice {
        FlashDevice(bsdName: bsdName, displayName: "SanDisk Cruzer Blade", sizeBytes: sizeBytes,
                    isWholeDisk: true, isExternal: true, isRemovableOrEjectable: true, isUSB: true,
                    isBootDisk: isBootDisk,
                    hardwareID: HardwareID(vendorID: 0x0781, productID: 0x5583, serialNumber: serial),
                    volumeNames: ["UNTITLED"], volumeUUIDs: ["OLD-UUID"])
    }

    // MARK: - Registration (PRD F28)

    func testRegisteringAFlashedDriveRecordsHardwareIdentityAndOneAssignment() async throws {
        let store = await makeStore()
        let drive = try store.registerFlashedDrive(device: device(), entryID: "arch",
                                                   channelID: "default")

        XCTAssertEqual(drive.kind, .flashed)
        XCTAssertEqual(drive.hardwareID?.serialNumber, "SERIAL-1")
        XCTAssertEqual(drive.lastBSDName, "disk4")
        XCTAssertEqual(drive.capacityBytes, 32 << 30)
        XCTAssertEqual(drive.assignments.count, 1)
        XCTAssertEqual(drive.volumeUUID, "OLD-UUID")
        XCTAssertTrue(drive.bookmark.isEmpty)          // PRD F28: no folder, no bookmark

        // Survives a relaunch as a flashed drive.
        let reloaded = AppStore(locations: StoreLocations(root: root), catalogResourceURL: nil)
        await reloaded.loadAtLaunch()
        XCTAssertEqual(reloaded.drives.first?.kind, .flashed)
        XCTAssertEqual(reloaded.drives.first?.hardwareID, drive.hardwareID)
    }

    func testTheSameStickCannotBeRegisteredTwice() async throws {
        let store = await makeStore()
        try store.registerFlashedDrive(device: device(), entryID: "arch", channelID: "default")
        // A different BSD name, same hardware: still the same stick (PRD F27).
        XCTAssertThrowsError(try store.registerFlashedDrive(device: device(bsdName: "disk7"),
                                                            entryID: "arch", channelID: "default")) { error in
            XCTAssertEqual(error as? FlashRegistrationError,
                           .alreadyRegistered("SanDisk Cruzer Blade"))
        }
    }

    func testTheBootDiskIsRefusedAtRegistration() async throws {
        let store = await makeStore()
        XCTAssertThrowsError(try store.registerFlashedDrive(device: device(isBootDisk: true),
                                                            entryID: "arch", channelID: "default"))
        XCTAssertTrue(store.drives.isEmpty)
    }

    func testADeviceWithNoUSBIdentityIsRefused() async throws {
        let store = await makeStore()
        var anonymous = device()
        anonymous.hardwareID = nil
        XCTAssertThrowsError(try store.registerFlashedDrive(device: anonymous, entryID: "arch",
                                                            channelID: "default")) { error in
            XCTAssertEqual(error as? FlashRegistrationError,
                           .noHardwareIdentity("SanDisk Cruzer Blade"))
        }
    }

    // MARK: - Identity & connection (PRD F27)

    func testAFlashedDriveIsConnectedWhenItsDeviceIsAttachedEvenWithNoVolume() async throws {
        let store = await makeStore()
        let drive = try store.registerFlashedDrive(device: device(), entryID: "arch",
                                                   channelID: "default")
        XCTAssertFalse(store.isConnected(drive))       // nothing attached yet

        var bare = device(bsdName: "disk9")
        bare.volumeNames = []
        bare.volumeUUIDs = []                          // a freshly flashed Linux image
        store.attachedDevices = [bare]
        XCTAssertTrue(store.isConnected(drive))
        XCTAssertEqual(store.attachedDevice(for: drive)?.bsdName, "disk9")

        // A different stick of the same model but a different serial is not it.
        store.attachedDevices = [device(serial: "SERIAL-2")]
        XCTAssertFalse(store.isConnected(drive))
    }

    func testRegistrablePickerHidesAlreadyRegisteredDevices() async throws {
        let store = await makeStore()
        let other = FlashDevice(bsdName: "disk6", displayName: "Kingston DataTraveler",
                                sizeBytes: 16 << 30, isWholeDisk: true, isExternal: true,
                                isRemovableOrEjectable: true, isUSB: true, isBootDisk: false,
                                hardwareID: HardwareID(vendorID: 0x0951, productID: 0x1666,
                                                       serialNumber: "K-1"),
                                volumeNames: [], volumeUUIDs: [])
        store.attachedDevices = [device(), other]
        XCTAssertEqual(store.registrableDevices().count, 2)
        try store.registerFlashedDrive(device: device(), entryID: "arch", channelID: "default")
        XCTAssertEqual(store.registrableDevices().map(\.bsdName), ["disk6"])
    }

    // MARK: - One image (PRD F26/F32)

    func testAssignmentIsReplacedNotAdded() async throws {
        let store = await makeStore()
        let drive = try store.registerFlashedDrive(device: device(), entryID: "arch",
                                                   channelID: "default")
        XCTAssertNil(store.addAssignment(entryID: "windows-11", channelID: "default", to: drive.id))
        XCTAssertEqual(store.drive(id: drive.id)?.assignments.count, 1)

        store.setFlashedAssignment(entryID: "windows-11", channelID: "default", on: drive.id)
        XCTAssertEqual(store.drive(id: drive.id)?.assignments.count, 1)
        XCTAssertEqual(store.drive(id: drive.id)?.singleAssignment?.entryID, "windows-11")
    }

    func testFlashablePickerExcludesWindows() async throws {
        let store = await makeStore()
        XCTAssertEqual(store.flashableEntries.map(\.id), ["arch"])
    }

    // MARK: - Plan (PRD F29/F30)

    func testFlashPlanDescribesTheDeviceAndTheImage() async throws {
        let store = await makeStore()
        let drive = try store.registerFlashedDrive(device: device(), entryID: "arch",
                                                   channelID: "default")
        store.attachedDevices = [device()]
        store.setRelease(Release(version: VersionToken.parse("2026.08.01")!,
                                 isoURL: URL(string: "https://example.com/arch-2026.08.01.iso")!,
                                 fileName: "arch-2026.08.01.iso", sha256: String(repeating: "a", count: 64),
                                 sizeBytes: 1 << 30),
                         for: ReleaseKey(entryID: "arch", channelID: "default"))

        let plan = try XCTUnwrap(store.flashPlan(driveID: drive.id))
        XCTAssertEqual(plan.device.bsdName, "disk4")
        XCTAssertEqual(plan.toVersion, "2026.08.01")
        XCTAssertEqual(plan.deviceSizeBytes, 32 << 30)
        XCTAssertTrue(plan.isVerifiable)
        XCTAssertNil(plan.gateFailure)
        XCTAssertTrue(plan.canFlash)

        // An ISO larger than the stick is refused in the dialog itself.
        store.setRelease(Release(version: VersionToken.parse("2026.08.01")!,
                                 isoURL: URL(string: "https://example.com/huge.iso")!,
                                 fileName: "huge.iso", sizeBytes: 64 << 30),
                         for: ReleaseKey(entryID: "arch", channelID: "default"))
        let refused = try XCTUnwrap(store.flashPlan(driveID: drive.id))
        XCTAssertFalse(refused.canFlash)
        XCTAssertEqual(refused.gateFailure,
                       .tooSmall(deviceName: "SanDisk Cruzer Blade",
                                 deviceBytes: 32 << 30, requiredBytes: 64 << 30))
    }

    func testNoPlanWithoutAnAttachedDevice() async throws {
        let store = await makeStore()
        let drive = try store.registerFlashedDrive(device: device(), entryID: "arch",
                                                   channelID: "default")
        store.setRelease(Release(version: VersionToken.parse("2026.08.01")!,
                                 isoURL: URL(string: "https://example.com/a.iso")!,
                                 fileName: "a.iso", sizeBytes: 1 << 30),
                         for: ReleaseKey(entryID: "arch", channelID: "default"))
        XCTAssertNil(store.flashPlan(driveID: drive.id))
    }

    // MARK: - Failure state (DESIGN §9)

    func testAFlaggedDriveShowsAsNeedingAttentionAndNeverUpToDate() async throws {
        let store = await makeStore()
        let drive = try store.registerFlashedDrive(device: device(), entryID: "arch",
                                                   channelID: "default")
        store.attachedDevices = [device()]
        store.setRelease(Release(version: VersionToken.parse("2026.08.01")!,
                                 isoURL: URL(string: "https://example.com/a.iso")!,
                                 fileName: "a.iso", sizeBytes: 1 << 30),
                         for: ReleaseKey(entryID: "arch", channelID: "default"))
        var installed = try XCTUnwrap(store.drive(id: drive.id))
        installed.assignments[0].installed = InstalledISO(fileName: "a.iso",
                                                          version: VersionToken.parse("2026.08.01"),
                                                          placedByApp: true)
        store.updateDrive(installed)
        XCTAssertEqual(store.status(of: try XCTUnwrap(store.drive(id: drive.id))), .upToDate)

        store.markFlashFailure(driveID: drive.id, reason: "the device was disconnected")
        let flagged = try XCTUnwrap(store.drive(id: drive.id))
        XCTAssertEqual(store.status(of: flagged), .needsAttention)
        XCTAssertEqual(store.staleness(of: flagged.assignments[0], on: flagged), .stale)
    }

    // MARK: - Update policy (PRD F37)

    func testAPinnedFlashedImageIsNeverAnnouncedAsAReflash() async throws {
        let store = await makeStore()
        let recorder = RecordingNotificationService()
        store.notifications = recorder
        let drive = try store.registerFlashedDrive(device: device(), entryID: "arch",
                                                   channelID: "default")
        store.attachedDevices = [device()]
        store.setRelease(Release(version: VersionToken.parse("2026.08.01")!,
                                 isoURL: URL(string: "https://example.com/a.iso")!,
                                 fileName: "arch-2026.08.01.iso", sizeBytes: 1 << 30),
                         for: ReleaseKey(entryID: "arch", channelID: "default"))
        var installed = try XCTUnwrap(store.drive(id: drive.id))
        installed.assignments[0].installed = InstalledISO(fileName: "arch-2026.07.01.iso",
                                                          version: VersionToken.parse("2026.07.01"),
                                                          placedByApp: true)
        store.updateDrive(installed)
        let assignmentID = installed.assignments[0].id
        XCTAssertEqual(store.status(of: try XCTUnwrap(store.drive(id: drive.id))), .updates(1))

        XCTAssertTrue(store.setUpdatePolicy(.keepAsIs, forAssignment: assignmentID, on: drive.id))
        store.announceUpdates(for: drive.id)
        try await Task.sleep(nanoseconds: 50_000_000)

        let pinnedDrive = try XCTUnwrap(store.drive(id: drive.id))
        XCTAssertTrue(recorder.driveNotices.isEmpty)
        XCTAssertEqual(store.staleness(of: pinnedDrive.assignments[0], on: pinnedDrive), .pinned)
        XCTAssertEqual(store.status(of: pinnedDrive), .upToDate)
        // PRD F26/F37: still exactly one assignment.
        XCTAssertEqual(pinnedDrive.assignments.count, 1)

        // A half-written stick still needs attention, but a pinned image is not
        // reported as an available update on top of that.
        store.markFlashFailure(driveID: drive.id, reason: "the device was disconnected")
        let flagged = try XCTUnwrap(store.drive(id: drive.id))
        XCTAssertEqual(store.status(of: flagged), .needsAttention)
        XCTAssertEqual(store.staleness(of: flagged.assignments[0], on: flagged), .pinned)

        // Un-pinning brings the reflash prompt back (F36).
        XCTAssertTrue(store.setUpdatePolicy(.trackLatest, forAssignment: assignmentID, on: drive.id))
        store.announceUpdates(for: drive.id)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(recorder.driveNotices.count, 1)
    }
}
