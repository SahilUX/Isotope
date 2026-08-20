import IsotopeCore
import XCTest
@testable import Isotope

/// PRD F41 (Ventoy content auto-detect) and F42 (status dot). Offline: the
/// volume probe and the folder listing are injected, and all state lives in a
/// temporary directory — no USB stick, no `Application Support`.
@MainActor
final class ContentDetectionTests: XCTestCase {
    private static let ubuntuPattern = #"^ubuntu-(\d+\.\d+(?:\.\d+)?)-desktop-amd64\.iso$"#
    private static let rescuePattern = #"^systemrescue-(\d+\.\d+)-amd64\.iso$"#

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeDetectTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func makeStore(volumes: [URL: VolumeInfo] = [:], listing: [String] = []) -> AppStore {
        let store = AppStore(locations: StoreLocations(root: root), catalogResourceURL: nil)
        store.driveProbe = DriveProbe(
            info: { url in
                guard let info = volumes[url] else { throw CocoaError(.fileReadNoSuchFile) }
                return info
            },
            bookmark: { url in Data("bookmark:\(url.path)".utf8) },
            listISOs: { _, _ in listing })
        return store
    }

    private func volume(_ path: String, uuid: String, name: String)
        -> (URL, VolumeInfo) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return (url, VolumeInfo(url: url, volumeUUID: uuid, name: name,
                                capacityBytes: 64_000_000_000, availableBytes: 32_000_000_000,
                                isReadOnly: false, isRemovable: true))
    }

    private var ubuntuEntry: CatalogEntry {
        let url = URL(string: "https://releases.ubuntu.invalid/SHA256SUMS")!
        return CatalogEntry(id: "ubuntu-desktop", name: "Ubuntu Desktop", kind: .linux,
                            channels: [
                                Channel(id: "lts", name: "LTS",
                                        provider: .checksumFile(url: url, filePattern: Self.ubuntuPattern)),
                                Channel(id: "latest", name: "Latest",
                                        provider: .checksumFile(url: url, filePattern: Self.ubuntuPattern)),
                            ],
                            isBuiltIn: false)
    }

    private var rescueEntry: CatalogEntry {
        CatalogEntry(id: "systemrescue", name: "SystemRescue", kind: .tool,
                     channels: [Channel(id: "default", name: "Default",
                                        provider: .checksumFile(
                                            url: URL(string: "https://rescue.invalid/sums")!,
                                            filePattern: Self.rescuePattern))],
                     isBuiltIn: false)
    }

    /// Registers a connected Ventoy drive with the given folder listing, scanned.
    private func connectedDrive(listing: [String]) async throws -> (AppStore, ManagedDrive) {
        let (url, info) = volume("/Volumes/VENTOY", uuid: "UUID-A", name: "VENTOY")
        let store = makeStore(volumes: [url: info], listing: listing)
        await store.loadAtLaunch()
        store.addCustomEntry(ubuntuEntry)
        store.addCustomEntry(rescueEntry)
        let drive = try store.registerDrive(at: url)
        store.scanAndReconcile(driveID: drive.id)
        return (store, try XCTUnwrap(store.drive(id: drive.id)))
    }

    // MARK: - F42: the status dot

    /// The bug: a connected drive with nothing assigned, or with an assignment
    /// no version comparison could be made for, rendered grey — the colour
    /// reserved for "not connected".
    func testConnectedDriveIsNeverReportedAsDisconnected() async throws {
        let (store, drive) = try await connectedDrive(listing: [])
        XCTAssertTrue(store.isConnected(drive))
        // No assignments at all — the state the user's freshly registered Ventoy
        // stick was in.
        XCTAssertEqual(store.status(of: drive), .unknown)
        XCTAssertEqual(store.status(of: drive).summary, "Nothing to update")
        XCTAssertNotEqual(store.status(of: drive), .disconnected)

        // An assignment whose channel was never checked: still not grey.
        let assignment = try XCTUnwrap(store.addAssignment(entryID: "ubuntu-desktop",
                                                           channelID: "lts", to: drive.id))
        var current = try XCTUnwrap(store.drive(id: drive.id))
        XCTAssertEqual(store.staleness(of: assignment), .unknown)
        XCTAssertEqual(store.status(of: current), .unknown)

        // Unplugged, and only then, grey.
        store.markDisconnected(volumeUUID: drive.volumeUUID)
        current = try XCTUnwrap(store.drive(id: drive.id))
        XCTAssertEqual(store.status(of: current), .disconnected)
    }

    /// The launch path: state is loaded from disk, then the initial volume
    /// enumeration marks what is plugged in as connected. Before it runs the
    /// drive is legitimately grey; after it, never.
    func testInitialEnumerationAtLaunchTurnsTheDotOn() async throws {
        let (url, info) = volume("/Volumes/VENTOY", uuid: "UUID-A", name: "VENTOY")
        let first = makeStore(volumes: [url: info])
        await first.loadAtLaunch()
        let drive = try first.registerDrive(at: url)

        // Relaunch: nothing is connected until the enumeration says so.
        let store = makeStore(volumes: [url: info])
        await store.loadAtLaunch()
        let loaded = try XCTUnwrap(store.drive(id: drive.id))
        XCTAssertEqual(store.status(of: loaded), .disconnected)

        // What `DriveMonitor.enumerateMountedVolumes()` does for each drive it
        // finds mounted — no mount *event* involved.
        store.markConnected(loaded, info: info)
        let connected = try XCTUnwrap(store.drive(id: drive.id))
        XCTAssertTrue(store.isConnected(connected))
        XCTAssertNotEqual(store.status(of: connected), .disconnected)
    }

    /// A flashed stick whose installed filename carries no parseable version —
    /// the user's Proxmox stick, labelled "PVE" — is green, not grey.
    func testConnectedFlashedDriveWithAnUnparseableVersionIsNotGrey() async throws {
        let store = makeStore()
        await store.loadAtLaunch()
        let hardware = HardwareID(vendorID: 0x0951, productID: 0x1666, serialNumber: "KINGSTON-1")
        let installed = InstalledISO(fileName: "PVE", version: nil, placedByApp: false)
        let drive = ManagedDrive(volumeUUID: "UUID-F", displayName: "Kingston DataTraveler",
                                 bookmark: Data(),
                                 assignments: [Assignment(entryID: "proxmox-ve", channelID: "default",
                                                          installed: installed)],
                                 kind: .flashed, hardwareID: hardware)
        store.addDrive(drive)
        XCTAssertEqual(store.status(of: drive), .disconnected)

        store.attachedDevices = [FlashDevice(bsdName: "disk4", displayName: "Kingston DataTraveler",
                                             sizeBytes: 64 << 30, isWholeDisk: true,
                                             isExternal: true, isRemovableOrEjectable: true,
                                             isUSB: true, isBootDisk: false, hardwareID: hardware,
                                             volumeNames: ["PVE"], volumeUUIDs: ["UUID-F"])]
        XCTAssertTrue(store.isConnected(drive))
        XCTAssertEqual(store.status(of: drive), .unknown)
        XCTAssertNotEqual(store.status(of: drive), .disconnected)
    }

    func testStaleAssignmentStillWinsOverTheUnknownOnes() async throws {
        let (store, drive) = try await connectedDrive(listing: [])
        let stale = try XCTUnwrap(store.addAssignment(entryID: "ubuntu-desktop",
                                                      channelID: "lts", to: drive.id))
        store.setRelease(Release(version: VersionToken.parse("24.04.3")!,
                                 fileName: "ubuntu-24.04.3-desktop-amd64.iso"),
                         for: stale.releaseKey)
        // A second assignment nothing is known about must not mask the update.
        _ = store.addAssignment(entryID: "systemrescue", channelID: "default", to: drive.id)
        XCTAssertEqual(store.status(of: try XCTUnwrap(store.drive(id: drive.id))), .updates(1))
    }

    // MARK: - F41: detection

    func testScanSplitsUnknownFilesIntoRecognisedAndUnrecognised() async throws {
        let (store, drive) = try await connectedDrive(
            listing: ["ubuntu-24.04.1-desktop-amd64.iso", "systemrescue-11.03-amd64.iso",
                      "holiday-backup.iso"])
        let detected = store.detectedISOs(on: drive)
        XCTAssertEqual(detected.map(\.entryID), ["systemrescue", "ubuntu-desktop"])
        XCTAssertEqual(detected.first?.channelID, "default")
        XCTAssertEqual(detected.first?.version, VersionToken.parse("11.03"))
        // Ubuntu's two channels share a pattern, so the channel is left open.
        XCTAssertNil(detected.last?.channelID)
        XCTAssertEqual(store.channels(for: try XCTUnwrap(detected.last)).map(\.id), ["lts", "latest"])
        XCTAssertEqual(store.unrecognizedISOFiles(on: drive), ["holiday-backup.iso"])
    }

    func testNothingIsAssignedUntilTheUserAsks() async throws {
        let (store, drive) = try await connectedDrive(listing: ["systemrescue-11.03-amd64.iso"])
        XCTAssertFalse(store.detectedISOs(on: drive).isEmpty)
        XCTAssertTrue(try XCTUnwrap(store.drive(id: drive.id)).assignments.isEmpty)
    }

    // MARK: - F41: adoption

    func testTrackLatestCreatesTheAssignmentClaimsTheFileAndPersists() async throws {
        let (store, drive) = try await connectedDrive(
            listing: ["systemrescue-11.03-amd64.iso", "holiday-backup.iso"])
        let detected = try XCTUnwrap(store.detectedISOs(on: drive).first)

        let created = try XCTUnwrap(store.adoptDetectedISO(detected, channelID: "default",
                                                            policy: .trackLatest, on: drive.id))
        XCTAssertEqual(created.entryID, "systemrescue")
        XCTAssertEqual(created.updatePolicy, .trackLatest)
        XCTAssertEqual(created.installed?.fileName, "systemrescue-11.03-amd64.iso")
        XCTAssertEqual(created.installed?.version, VersionToken.parse("11.03"))
        XCTAssertEqual(created.installed?.placedByApp, false)

        // The file is claimed: it is no longer offered, and no longer unknown.
        let updated = try XCTUnwrap(store.drive(id: drive.id))
        XCTAssertTrue(store.detectedISOs(on: updated).isEmpty)
        XCTAssertEqual(store.unknownISOFiles[drive.id], ["holiday-backup.iso"])
        XCTAssertEqual(store.unrecognizedISOFiles(on: updated), ["holiday-backup.iso"])

        // And it survives a relaunch.
        let reloaded = makeStore()
        await reloaded.loadAtLaunch()
        XCTAssertEqual(reloaded.drive(id: drive.id)?.assignments.first?.installed?.fileName,
                       "systemrescue-11.03-amd64.iso")
    }

    func testPinAsIsRecordsTheFileAndNeverGoesStale() async throws {
        let (store, drive) = try await connectedDrive(listing: ["ubuntu-22.04.5-desktop-amd64.iso"])
        let detected = try XCTUnwrap(store.detectedISOs(on: drive).first)
        let created = try XCTUnwrap(store.adoptDetectedISO(detected, channelID: "lts",
                                                            policy: .keepAsIs, on: drive.id))
        XCTAssertTrue(created.isPinned)
        store.setRelease(Release(version: VersionToken.parse("24.04.3")!,
                                 fileName: "ubuntu-24.04.3-desktop-amd64.iso"),
                         for: created.releaseKey)
        XCTAssertEqual(store.staleness(of: created), .pinned)
        XCTAssertEqual(store.status(of: try XCTUnwrap(store.drive(id: drive.id))), .upToDate)
    }

    /// PRD F34: a tracker for an entry+channel already exists, so the second copy
    /// may only be pinned — "Track latest" is not offered for it.
    func testASecondCopyBesideATrackerIsOfferedOnlyAsAPin() async throws {
        let (store, drive) = try await connectedDrive(
            listing: ["ubuntu-24.04.3-desktop-amd64.iso", "ubuntu-22.04.5-desktop-amd64.iso"])
        let tracker = try XCTUnwrap(store.addAssignment(entryID: "ubuntu-desktop",
                                                        channelID: "lts", to: drive.id))
        // The tracker takes the highest version; the older copy stays unclaimed.
        XCTAssertEqual(store.drive(id: drive.id)?.assignments.first?.installed?.fileName,
                       "ubuntu-24.04.3-desktop-amd64.iso")
        var current = try XCTUnwrap(store.drive(id: drive.id))
        let detected = try XCTUnwrap(store.detectedISOs(on: current).first)
        XCTAssertEqual(detected.fileName, "ubuntu-22.04.5-desktop-amd64.iso")

        XCTAssertFalse(store.canAdopt(detected, channelID: "lts", policy: .trackLatest, on: current))
        XCTAssertTrue(store.canAdopt(detected, channelID: "lts", policy: .keepAsIs, on: current))
        XCTAssertNil(store.adoptDetectedISO(detected, channelID: "lts", policy: .trackLatest,
                                            on: drive.id))
        // The other channel has no tracker, so it may still be tracked.
        XCTAssertTrue(store.canAdopt(detected, channelID: "latest", policy: .trackLatest, on: current))

        let pinned = try XCTUnwrap(store.adoptDetectedISO(detected, channelID: "lts",
                                                           policy: .keepAsIs, on: drive.id))
        current = try XCTUnwrap(store.drive(id: drive.id))
        XCTAssertEqual(current.assignments.count, 2)
        // Each assignment keeps its own file — the pin does not steal the newer
        // one, and the tracker does not take the pinned copy.
        XCTAssertEqual(current.assignments.first { $0.id == tracker.id }?.installed?.fileName,
                       "ubuntu-24.04.3-desktop-amd64.iso")
        XCTAssertEqual(current.assignments.first { $0.id == pinned.id }?.installed?.fileName,
                       "ubuntu-22.04.5-desktop-amd64.iso")
        XCTAssertEqual(store.unknownISOFiles[drive.id], [])
        XCTAssertTrue(store.detectedISOs(on: current).isEmpty)
    }

    func testAdoptingAFileThatIsNoLongerUnclaimedIsRefused() async throws {
        let (store, drive) = try await connectedDrive(listing: ["systemrescue-11.03-amd64.iso"])
        let detected = try XCTUnwrap(store.detectedISOs(on: drive).first)
        XCTAssertNotNil(store.adoptDetectedISO(detected, channelID: "default",
                                               policy: .trackLatest, on: drive.id))
        // A second click on a stale offer creates nothing.
        XCTAssertNil(store.adoptDetectedISO(detected, channelID: "default",
                                            policy: .keepAsIs, on: drive.id))
        XCTAssertEqual(store.drive(id: drive.id)?.assignments.count, 1)
    }

    /// A flashed drive has no ISO folder, so it never offers anything (PRD F26).
    func testFlashedDrivesNeverOfferDetections() async throws {
        let store = makeStore()
        await store.loadAtLaunch()
        let drive = ManagedDrive(volumeUUID: "UUID-F", displayName: "Kingston", bookmark: Data(),
                                 kind: .flashed,
                                 hardwareID: HardwareID(vendorID: 1, productID: 2, serialNumber: "S"))
        store.addDrive(drive)
        store.unknownISOFiles[drive.id] = ["systemrescue-11.03-amd64.iso"]
        XCTAssertTrue(store.detectedISOs(on: drive).isEmpty)
    }
}
