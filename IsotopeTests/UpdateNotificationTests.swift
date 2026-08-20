import IsotopeCore
import XCTest
@testable import Isotope

/// PRD F16 (drive-connect notification) and F23 (no eject while busy). The
/// notification service is injected, so nothing here touches
/// `UNUserNotificationCenter` — which would trap in a test bundle.
@MainActor
final class UpdateNotificationTests: XCTestCase {
    private var root: URL!
    private var volume: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeNotifyTests-\(UUID().uuidString)")
        volume = root.appendingPathComponent("VENTOY", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() async throws -> (AppStore, RecordingNotificationService, ManagedDrive) {
        let store = AppStore(locations: StoreLocations(root: root.appendingPathComponent("state")),
                             catalogResourceURL: nil)
        let path = volume.path
        store.driveProbe = DriveProbe(
            info: { url in
                VolumeInfo(url: url, volumeUUID: "UUID-A", name: "VENTOY", capacityBytes: 64 << 30,
                           availableBytes: 32 << 30, isReadOnly: false, isRemovable: true)
            },
            bookmark: { _ in Data(path.utf8) },
            listISOs: { _, _ in [] })
        await store.loadAtLaunch()
        let recorder = RecordingNotificationService()
        store.notifications = recorder
        store.addCustomEntry(CatalogEntry(id: "ubuntu", name: "Ubuntu Desktop", kind: .linux,
                                          channels: [Channel(id: "lts", name: "LTS",
                                                             provider: .staticURL(url: URL(string: "https://example.test/x.iso")!,
                                                                                  checksumURL: nil))],
                                          isBuiltIn: false))
        let drive = try store.registerDrive(at: volume)
        return (store, recorder, drive)
    }

    func testConnectingADriveWithStaleAssignmentsPostsOneSummaryNotification() async throws {
        let (store, recorder, drive) = try await makeStore()
        store.addAssignment(entryID: "ubuntu", channelID: "lts", to: drive.id)
        store.setRelease(Release(version: .parse("24.04.4")!, fileName: "ubuntu-24.04.4.iso"),
                         for: ReleaseKey(entryID: "ubuntu", channelID: "lts"))

        store.announceUpdates(for: drive.id)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(recorder.driveNotices.count, 1)
        XCTAssertEqual(recorder.driveNotices.first?.driveName, "VENTOY")
        XCTAssertEqual(recorder.driveNotices.first?.summaries, ["Ubuntu Desktop 24.04.4"])
    }

    func testReconnectingTheSameDriveDoesNotRepeatTheNotification() async throws {
        let (store, recorder, drive) = try await makeStore()
        store.addAssignment(entryID: "ubuntu", channelID: "lts", to: drive.id)
        store.setRelease(Release(version: .parse("24.04.4")!, fileName: "ubuntu-24.04.4.iso"),
                         for: ReleaseKey(entryID: "ubuntu", channelID: "lts"))

        store.announceUpdates(for: drive.id)
        store.announceUpdates(for: drive.id)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(recorder.driveNotices.count, 1)

        // A *new* release is a new announcement.
        store.setRelease(Release(version: .parse("24.04.5")!, fileName: "ubuntu-24.04.5.iso"),
                         for: ReleaseKey(entryID: "ubuntu", channelID: "lts"))
        store.announceUpdates(for: drive.id)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(recorder.driveNotices.count, 2)
    }

    func testAnUpToDateDriveIsSilent() async throws {
        let (store, recorder, drive) = try await makeStore()
        store.addAssignment(entryID: "ubuntu", channelID: "lts", to: drive.id)
        var updated = store.drive(id: drive.id)!
        updated.assignments[0].installed = InstalledISO(fileName: "ubuntu-24.04.4.iso",
                                                        version: .parse("24.04.4"), placedByApp: true)
        store.updateDrive(updated)
        store.setRelease(Release(version: .parse("24.04.4")!, fileName: "ubuntu-24.04.4.iso"),
                         for: ReleaseKey(entryID: "ubuntu", channelID: "lts"))

        store.announceUpdates(for: drive.id)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(recorder.driveNotices.isEmpty)
    }

    /// PRD F36: a pinned assignment is not an update — no banner, no count, and
    /// nothing for "Update All" to do.
    func testAPinnedAssignmentIsNeverAnnouncedOrCounted() async throws {
        let (store, recorder, drive) = try await makeStore()
        let assignment = try XCTUnwrap(store.addAssignment(entryID: "ubuntu", channelID: "lts",
                                                            to: drive.id))
        var updated = store.drive(id: drive.id)!
        updated.assignments[0].installed = InstalledISO(fileName: "ubuntu-22.04.1.iso",
                                                        version: .parse("22.04.1"), placedByApp: true)
        store.updateDrive(updated)
        store.setRelease(Release(version: .parse("24.04.4")!, fileName: "ubuntu-24.04.4.iso"),
                         for: ReleaseKey(entryID: "ubuntu", channelID: "lts"))

        XCTAssertTrue(store.setUpdatePolicy(.keepAsIs, forAssignment: assignment.id, on: drive.id))
        store.announceUpdates(for: drive.id)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(recorder.driveNotices.isEmpty)
        XCTAssertEqual(store.staleness(of: store.drive(id: drive.id)!.assignments[0]), .pinned)
        XCTAssertTrue(store.staleAssignments(on: store.drive(id: drive.id)!).isEmpty)
        XCTAssertEqual(store.status(of: store.drive(id: drive.id)!), .upToDate)

        // PRD F36: back to tracking → staleness is re-evaluated and announced.
        XCTAssertTrue(store.setUpdatePolicy(.trackLatest, forAssignment: assignment.id, on: drive.id))
        store.announceUpdates(for: drive.id)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(recorder.driveNotices.count, 1)
        XCTAssertEqual(store.status(of: store.drive(id: drive.id)!), .updates(1))
    }

    /// PRD F23: Eject stays disabled while a copy is in flight.
    func testEjectIsBlockedWhileAnOperationIsInFlight() async throws {
        let (store, _, drive) = try await makeStore()
        let release = Release(version: .parse("24.04.4")!,
                              isoURL: URL(string: "https://example.test/x.iso"),
                              fileName: "ubuntu-24.04.4.iso")
        let request = UpdateRequest(driveID: drive.id, driveName: drive.displayName,
                                    assignmentID: UUID(), entryID: "ubuntu", channelID: "lts",
                                    title: "Ubuntu Desktop — LTS", release: release)

        store.beginOperation(for: request)
        XCTAssertTrue(store.hasOperationsInFlight(store.drive(id: drive.id)!))
        // `eject` is a no-op rather than an error while busy — the button is
        // disabled in the UI, this is the belt-and-braces half.
        XCTAssertNoThrow(try store.eject(driveID: drive.id))
        XCTAssertTrue(store.isConnected(store.drive(id: drive.id)!))

        store.finishOperation(request: request, result: .failure(.cancelled))
        XCTAssertFalse(store.hasOperationsInFlight(store.drive(id: drive.id)!))
        XCTAssertEqual(store.history.first?.outcome, .cancelled)
    }
}
