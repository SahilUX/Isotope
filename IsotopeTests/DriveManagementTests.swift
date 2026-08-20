import IsotopeCore
import XCTest
@testable import Isotope

/// Phase 3 drive management, entirely offline: the volume probe is injected, so
/// no USB stick, open panel or mounted volume is involved.
@MainActor
final class DriveManagementTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeDriveTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(volumes: [URL: VolumeInfo] = [:], listing: [String] = []) -> AppStore {
        let store = AppStore(locations: StoreLocations(root: root), catalogResourceURL: nil)
        store.driveProbe = DriveProbe(
            info: { url in
                guard let info = volumes[url] else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                return info
            },
            bookmark: { url in Data("bookmark:\(url.path)".utf8) },
            listISOs: { _, _ in listing })
        return store
    }

    private func volume(_ path: String, uuid: String?, name: String,
                        capacity: Int64 = 64_000_000_000) -> (URL, VolumeInfo) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return (url, VolumeInfo(url: url, volumeUUID: uuid, name: name,
                                capacityBytes: capacity, availableBytes: capacity / 2,
                                isReadOnly: false, isRemovable: true))
    }

    // MARK: - Registration (PRD F1)

    func testRegisterDrivePersistsAcrossRelaunch() async throws {
        let (url, info) = volume("/Volumes/VENTOY", uuid: "UUID-A", name: "VENTOY")
        let store = makeStore(volumes: [url: info])
        await store.loadAtLaunch()

        let drive = try store.registerDrive(at: url)
        XCTAssertEqual(drive.volumeUUID, "UUID-A")
        XCTAssertEqual(drive.displayName, "VENTOY")
        XCTAssertEqual(drive.capacityBytes, 64_000_000_000)
        XCTAssertEqual(drive.bookmark, Data("bookmark:/Volumes/VENTOY".utf8))
        XCTAssertNotNil(drive.lastSeenAt)
        // Registration also marks it connected, without waiting for a mount event.
        XCTAssertTrue(store.isConnected(drive))

        let reloaded = makeStore(volumes: [url: info])
        await reloaded.loadAtLaunch()
        XCTAssertEqual(reloaded.drives.map(\.id), [drive.id])
        XCTAssertEqual(reloaded.drives.first?.volumeUUID, "UUID-A")
        // Nothing is connected until the monitor enumerates volumes.
        XCTAssertFalse(reloaded.isConnected(try XCTUnwrap(reloaded.drives.first)))
    }

    func testDuplicateVolumeUUIDIsRejected() async throws {
        let (url, info) = volume("/Volumes/VENTOY", uuid: "UUID-A", name: "VENTOY")
        // Same stick, mounted at a second path (macOS appends " 1" on remount).
        let (otherURL, otherInfo) = volume("/Volumes/VENTOY 1", uuid: "UUID-A", name: "VENTOY 1")
        let store = makeStore(volumes: [url: info, otherURL: otherInfo])
        await store.loadAtLaunch()
        try store.registerDrive(at: url)

        XCTAssertThrowsError(try store.registerDrive(at: otherURL)) { error in
            XCTAssertEqual(error as? DriveRegistrationError, .alreadyRegistered("VENTOY"))
            XCTAssertNotNil((error as? DriveRegistrationError)?.errorDescription)
        }
        XCTAssertEqual(store.drives.count, 1)
    }

    func testVolumeWithoutUUIDIsRejected() async throws {
        let (url, info) = volume("/Volumes/Disk Image", uuid: nil, name: "Disk Image")
        let store = makeStore(volumes: [url: info])
        await store.loadAtLaunch()
        XCTAssertThrowsError(try store.registerDrive(at: url)) { error in
            XCTAssertEqual(error as? DriveRegistrationError, .noVolumeUUID("Disk Image"))
        }
        XCTAssertTrue(store.drives.isEmpty)
    }

    func testUnreadableVolumeIsReportedNotCrashed() async throws {
        let store = makeStore()
        await store.loadAtLaunch()
        let url = URL(fileURLWithPath: "/Volumes/Gone", isDirectory: true)
        XCTAssertThrowsError(try store.registerDrive(at: url)) { error in
            guard case .unreadable = error as? DriveRegistrationError else {
                return XCTFail("expected .unreadable, got \(error)")
            }
        }
    }

    /// PRD F5: unregistering forgets tracking only, and clears transient state.
    func testUnregisterDropsTrackingAndSelection() async throws {
        let (url, info) = volume("/Volumes/VENTOY", uuid: "UUID-A", name: "VENTOY")
        let store = makeStore(volumes: [url: info])
        await store.loadAtLaunch()
        let drive = try store.registerDrive(at: url)
        store.unknownISOFiles[drive.id] = ["stray.iso"]
        store.setIssue(.unreadable("boom"), for: drive.id)
        store.selection = .drive(drive.id)

        store.unregisterDrive(id: drive.id)
        XCTAssertTrue(store.drives.isEmpty)
        XCTAssertNil(store.driveIssues[drive.id])
        XCTAssertNil(store.unknownISOFiles[drive.id])
        XCTAssertEqual(store.selection, .drives)

        let reloaded = makeStore()
        await reloaded.loadAtLaunch()
        XCTAssertTrue(reloaded.drives.isEmpty)
    }

    // MARK: - Connection state (PRD F2/F3)

    func testMarkConnectedUpdatesLastSeenNameAndCapacity() async throws {
        let (url, info) = volume("/Volumes/VENTOY", uuid: "UUID-A", name: "VENTOY")
        let store = makeStore(volumes: [url: info])
        await store.loadAtLaunch()
        var drive = try store.registerDrive(at: url)
        store.markDisconnected(volumeUUID: drive.volumeUUID)
        XCTAssertFalse(store.isConnected(drive))

        // Renamed stick, same UUID: identity survives, the label follows.
        let renamed = VolumeInfo(url: url, volumeUUID: "UUID-A", name: "TOOLBOX",
                                 capacityBytes: 128_000_000_000, availableBytes: 100,
                                 isReadOnly: false, isRemovable: true)
        let seenAt = Date(timeIntervalSince1970: 2_000)
        store.markConnected(drive, info: renamed, at: seenAt)

        drive = try XCTUnwrap(store.drive(id: drive.id))
        XCTAssertTrue(store.isConnected(drive))
        XCTAssertEqual(drive.displayName, "TOOLBOX")
        XCTAssertEqual(drive.capacityBytes, 128_000_000_000)
        XCTAssertEqual(drive.lastSeenAt, seenAt)
    }

    func testStatusReflectsConnectionIssuesAndStaleness() async throws {
        let (url, info) = volume("/Volumes/VENTOY", uuid: "UUID-A", name: "VENTOY")
        let store = makeStore(volumes: [url: info])
        await store.loadAtLaunch()
        store.addCustomEntry(ubuntuEntry)
        var drive = try store.registerDrive(at: url)

        // Connected, no assignments → nothing to compare.
        XCTAssertEqual(store.status(of: drive), .unknown)

        let assignment = try XCTUnwrap(store.addAssignment(entryID: "ubuntu-desktop",
                                                           channelID: "lts", to: drive.id))
        store.setRelease(Release(version: VersionToken.parse("24.04.3")!,
                                 fileName: "ubuntu-24.04.3-desktop-amd64.iso"),
                         for: assignment.releaseKey)
        drive = try XCTUnwrap(store.drive(id: drive.id))
        XCTAssertEqual(store.status(of: drive), .updates(1))   // nothing installed yet

        store.apply(ReconcileResult(outcomes: [ReconcileOutcome(
            assignmentID: assignment.id,
            installed: InstalledISO(fileName: "ubuntu-24.04.3-desktop-amd64.iso",
                                    version: VersionToken.parse("24.04.3"), placedByApp: false),
            change: .discovered)], unknownFiles: [], scannedAt: Date()), to: drive.id)
        drive = try XCTUnwrap(store.drive(id: drive.id))
        XCTAssertEqual(store.status(of: drive), .upToDate)

        store.setIssue(.changed(volumeName: "UNTITLED", foundUUID: "UUID-B"), for: drive.id)
        XCTAssertEqual(store.status(of: drive), .needsAttention)

        store.setIssue(nil, for: drive.id)
        store.markDisconnected(volumeUUID: drive.volumeUUID)
        XCTAssertEqual(store.status(of: drive), .disconnected)
    }

    // MARK: - Assignments

    func testDuplicateEntryChannelAssignmentIsPrevented() async throws {
        let (url, info) = volume("/Volumes/VENTOY", uuid: "UUID-A", name: "VENTOY")
        let store = makeStore(volumes: [url: info])
        await store.loadAtLaunch()
        store.addCustomEntry(ubuntuEntry)
        let drive = try store.registerDrive(at: url)

        XCTAssertNotNil(store.addAssignment(entryID: "ubuntu-desktop", channelID: "lts", to: drive.id))
        XCTAssertNil(store.addAssignment(entryID: "ubuntu-desktop", channelID: "lts", to: drive.id))
        // A different channel of the same entry is fine.
        XCTAssertNotNil(store.addAssignment(entryID: "ubuntu-desktop", channelID: "latest", to: drive.id))
        XCTAssertEqual(store.drive(id: drive.id)?.assignments.count, 2)
    }

    /// PRD F34: the same entry+channel may repeat as long as one tracker leads.
    func testASecondAssignmentOfOneChannelIsAllowedOnlyAsAPinnedCopy() async throws {
        let (url, info) = volume("/Volumes/VENTOY", uuid: "UUID-A", name: "VENTOY")
        let store = makeStore(volumes: [url: info])
        await store.loadAtLaunch()
        store.addCustomEntry(ubuntuEntry)
        let drive = try store.registerDrive(at: url)

        let tracker = try XCTUnwrap(store.addAssignment(entryID: "ubuntu-desktop", channelID: "lts",
                                                         to: drive.id))
        // A pinned duplicate is fine; a second tracker is not.
        let pinned = try XCTUnwrap(store.addAssignment(entryID: "ubuntu-desktop", channelID: "lts",
                                                        to: drive.id, policy: .keepAsIs))
        XCTAssertNil(store.addAssignment(entryID: "ubuntu-desktop", channelID: "lts", to: drive.id))
        XCTAssertEqual(store.drive(id: drive.id)?.assignments.count, 2)

        // The picker follows the same rule.
        var current = try XCTUnwrap(store.drive(id: drive.id))
        XCTAssertFalse(store.canAssign(entryID: "ubuntu-desktop", channelID: "lts", to: current))
        XCTAssertTrue(store.canAssign(entryID: "ubuntu-desktop", channelID: "lts",
                                      policy: .keepAsIs, to: current))
        XCTAssertTrue(store.canAssign(entryID: "ubuntu-desktop", channelID: "latest", to: current))

        // The pinned copy cannot take over while the tracker is still tracking…
        XCTAssertFalse(store.setUpdatePolicy(.trackLatest, forAssignment: pinned.id, on: drive.id))
        // …but it can once the tracker is pinned itself.
        XCTAssertTrue(store.setUpdatePolicy(.keepAsIs, forAssignment: tracker.id, on: drive.id))
        XCTAssertTrue(store.setUpdatePolicy(.trackLatest, forAssignment: pinned.id, on: drive.id))

        current = try XCTUnwrap(store.drive(id: drive.id))
        XCTAssertEqual(current.assignments.first { $0.id == tracker.id }?.updatePolicy, .keepAsIs)
        XCTAssertEqual(current.assignments.first { $0.id == pinned.id }?.updatePolicy, .trackLatest)

        // And the policy is persisted.
        let reloaded = makeStore()
        await reloaded.loadAtLaunch()
        XCTAssertEqual(reloaded.drive(id: drive.id)?.assignments.map(\.updatePolicy),
                       [.keepAsIs, .trackLatest])
    }

    func testRemoveAssignmentPersists() async throws {
        let (url, info) = volume("/Volumes/VENTOY", uuid: "UUID-A", name: "VENTOY")
        let store = makeStore(volumes: [url: info])
        await store.loadAtLaunch()
        store.addCustomEntry(ubuntuEntry)
        let drive = try store.registerDrive(at: url)
        let assignment = try XCTUnwrap(store.addAssignment(entryID: "ubuntu-desktop",
                                                           channelID: "lts", to: drive.id))
        store.removeAssignment(id: assignment.id, from: drive.id)

        let reloaded = makeStore()
        await reloaded.loadAtLaunch()
        XCTAssertEqual(reloaded.drive(id: drive.id)?.assignments.count, 0)
    }

    // MARK: - Reconcile plumbing (PRD F7)

    func testReconcileInputsCarryThePatternAndCachedRelease() async throws {
        let (url, info) = volume("/Volumes/VENTOY", uuid: "UUID-A", name: "VENTOY")
        let store = makeStore(volumes: [url: info])
        await store.loadAtLaunch()
        store.addCustomEntry(ubuntuEntry)
        let drive = try store.registerDrive(at: url)
        let assignment = try XCTUnwrap(store.addAssignment(entryID: "ubuntu-desktop",
                                                           channelID: "lts", to: drive.id))
        store.setRelease(Release(version: VersionToken.parse("24.04.3")!,
                                 fileName: "ubuntu-24.04.3-desktop-amd64.iso"),
                         for: assignment.releaseKey)

        let inputs = store.reconcileInputs(for: try XCTUnwrap(store.drive(id: drive.id)))
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs.first?.fileNamePattern, Self.ubuntuPattern)
        XCTAssertEqual(inputs.first?.releaseFileName, "ubuntu-24.04.3-desktop-amd64.iso")
        XCTAssertEqual(inputs.first?.releaseVersion, VersionToken.parse("24.04.3"))

        // End-to-end through the pure reconciler, from a fake listing.
        let result = DriveReconciler.reconcile(
            fileNames: ["ubuntu-24.04.3-desktop-amd64.iso", "stray.iso"], assignments: inputs)
        store.apply(result, to: drive.id)
        XCTAssertEqual(store.drive(id: drive.id)?.assignments.first?.installed?.fileName,
                       "ubuntu-24.04.3-desktop-amd64.iso")
        XCTAssertEqual(store.unknownISOFiles[drive.id], ["stray.iso"])
        XCTAssertNotNil(store.lastScanAt[drive.id])

        // Reconciled state survives a relaunch.
        let reloaded = makeStore()
        await reloaded.loadAtLaunch()
        XCTAssertEqual(reloaded.drive(id: drive.id)?.assignments.first?.installed?.version,
                       VersionToken.parse("24.04.3"))
    }

    /// The full on-connect path (PRD F7) with the folder listing injected.
    func testScanAndReconcileRecognisesAndThenLosesAFile() async throws {
        let (url, info) = volume("/Volumes/VENTOY", uuid: "UUID-A", name: "VENTOY")
        let store = makeStore(volumes: [url: info],
                              listing: ["ubuntu-24.04.1-desktop-amd64.iso", "rescue.iso"])
        await store.loadAtLaunch()
        store.addCustomEntry(ubuntuEntry)
        let drive = try store.registerDrive(at: url)
        // addAssignment scans immediately, so the existing file is picked up.
        _ = try XCTUnwrap(store.addAssignment(entryID: "ubuntu-desktop", channelID: "lts", to: drive.id))

        let installed = try XCTUnwrap(store.drive(id: drive.id)?.assignments.first?.installed)
        XCTAssertEqual(installed.fileName, "ubuntu-24.04.1-desktop-amd64.iso")
        XCTAssertEqual(installed.version, VersionToken.parse("24.04.1"))
        XCTAssertFalse(installed.placedByApp)
        XCTAssertEqual(store.unknownISOFiles[drive.id], ["rescue.iso"])
        XCTAssertNil(store.driveIssues[drive.id])

        // The user deletes the ISO by hand: the assignment is flagged, not fixed.
        store.driveProbe.listISOs = { _, _ in [] }
        let result = try XCTUnwrap(store.scanAndReconcile(driveID: drive.id))
        XCTAssertEqual(result.changes.first?.change, .missing)
        XCTAssertNil(store.drive(id: drive.id)?.assignments.first?.installed)
        XCTAssertEqual(store.unknownISOFiles[drive.id], [])
    }

    /// A scan on a drive whose folder cannot be read records an issue instead of
    /// wiping the recorded installs.
    func testUnreadableISOFolderRecordsAnIssue() async throws {
        let (url, info) = volume("/Volumes/VENTOY", uuid: "UUID-A", name: "VENTOY")
        let store = makeStore(volumes: [url: info])
        await store.loadAtLaunch()
        let drive = try store.registerDrive(at: url)
        store.driveProbe.listISOs = { _, _ in throw CocoaError(.fileReadNoPermission) }

        XCTAssertNil(store.scanAndReconcile(driveID: drive.id))
        guard case .unreadable = store.driveIssues[drive.id] else {
            return XCTFail("expected an .unreadable issue")
        }
        XCTAssertEqual(store.status(of: try XCTUnwrap(store.drive(id: drive.id))), .needsAttention)
    }

    func testReleaseCacheStalenessDrivesTheMountCheck() async throws {
        let (url, info) = volume("/Volumes/VENTOY", uuid: "UUID-A", name: "VENTOY")
        let store = makeStore(volumes: [url: info])
        await store.loadAtLaunch()
        store.addCustomEntry(ubuntuEntry)
        let drive = try store.registerDrive(at: url)
        // No assignments at all → nothing to check.
        XCTAssertFalse(store.releaseCacheIsStale(for: try XCTUnwrap(store.drive(id: drive.id))))

        let assignment = try XCTUnwrap(store.addAssignment(entryID: "ubuntu-desktop",
                                                           channelID: "lts", to: drive.id))
        // Assigned but never checked → stale.
        XCTAssertTrue(store.releaseCacheIsStale(for: try XCTUnwrap(store.drive(id: drive.id))))

        let now = Date()
        store.setRelease(Release(version: VersionToken.parse("24.04.3")!,
                                 fileName: "ubuntu-24.04.3-desktop-amd64.iso",
                                 checkedAt: now.addingTimeInterval(-60)),
                         for: assignment.releaseKey)
        let fresh = try XCTUnwrap(store.drive(id: drive.id))
        XCTAssertFalse(store.releaseCacheIsStale(for: fresh, now: now))
        XCTAssertTrue(store.releaseCacheIsStale(for: fresh, maxAge: 30, now: now))

        XCTAssertEqual(store.channelJobs(for: fresh).map(\.key.description), ["ubuntu-desktop#lts"])
    }

    // MARK: - Drive settings (PRD F6)

    func testISOFolderAndKeepOldVersionsPersist() async throws {
        let (url, info) = volume("/Volumes/VENTOY", uuid: "UUID-A", name: "VENTOY")
        let store = makeStore(volumes: [url: info])
        await store.loadAtLaunch()
        let drive = try store.registerDrive(at: url)
        store.setISOFolder("ISOs", for: drive.id)
        store.setKeepOldVersions(true, for: drive.id)

        let reloaded = makeStore()
        await reloaded.loadAtLaunch()
        XCTAssertEqual(reloaded.drive(id: drive.id)?.isoFolder, "ISOs")
        XCTAssertEqual(reloaded.drive(id: drive.id)?.keepOldVersions, true)
    }

    // MARK: - Path helpers

    func testISOFolderURLResolution() {
        let volume = URL(fileURLWithPath: "/Volumes/VENTOY", isDirectory: true)
        XCTAssertEqual(DriveAccess.isoFolderURL(volume: volume, isoFolder: "").path, "/Volumes/VENTOY")
        XCTAssertEqual(DriveAccess.isoFolderURL(volume: volume, isoFolder: "ISOs").path,
                       "/Volumes/VENTOY/ISOs")
        XCTAssertEqual(DriveAccess.isoFolderURL(volume: volume, isoFolder: "/ISOs/linux/").path,
                       "/Volumes/VENTOY/ISOs/linux")
        // Traversal out of the volume is not expressible (PRD F22).
        XCTAssertEqual(DriveAccess.isoFolderURL(volume: volume, isoFolder: "../../etc").path,
                       "/Volumes/VENTOY/etc")
    }

    // MARK: - Fixtures

    private static let ubuntuPattern = #"ubuntu-(\d+\.\d+(?:\.\d+)?)-desktop-amd64\.iso"#

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
}
