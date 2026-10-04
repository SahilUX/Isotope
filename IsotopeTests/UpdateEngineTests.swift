import IsotopeCore
import XCTest
@testable import Isotope

/// Phase 4 pipeline, entirely offline: the download provider and the volume
/// metadata are injected, but the copy, rename and delete run against a real
/// temporary directory standing in for the USB stick (DESIGN §4.5).
@MainActor
final class UpdateEngineTests: XCTestCase {
    private var root: URL!
    private var volume: URL!
    private var cacheDir: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeUpdateTests-\(UUID().uuidString)")
        volume = root.appendingPathComponent("VENTOY", isDirectory: true)
        cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture

    private struct Fixture {
        var store: AppStore
        var engine: UpdateEngine
        var provider: FakeISOProvider
        var writer: FakeDriveWriter
        var driveID: UUID
        var assignmentID: UUID
        var release: Release
    }

    private func makeFixture(installed: InstalledISO? = nil,
                             keepOldVersions: Bool = false,
                             sha256: String? = "abc123",
                             availableBytes: Int64 = 64 << 30,
                             isoSize: Int = 256 * 1024,
                             installedSize: Int = 64 * 1024,
                             provider behaviour: FakeISOProvider.Behaviour? = nil) async throws -> Fixture {
        let store = AppStore(locations: StoreLocations(root: root.appendingPathComponent("state")),
                             catalogResourceURL: nil)
        let volumePath = volume.path
        store.driveProbe = DriveProbe(
            info: { url in
                VolumeInfo(url: url, volumeUUID: "UUID-A", name: "VENTOY",
                           capacityBytes: 64 << 30, availableBytes: availableBytes,
                           isReadOnly: false, isRemovable: true)
            },
            bookmark: { _ in Data(volumePath.utf8) },
            listISOs: { _, _ in [] })

        await store.loadAtLaunch()
        store.addCustomEntry(CatalogEntry(
            id: "ubuntu", name: "Ubuntu Desktop", kind: .linux, channels: [
                Channel(id: "lts", name: "LTS",
                        provider: .checksumFile(url: URL(string: "https://example.test/SHA256SUMS")!,
                                                filePattern: #"ubuntu-(\d+\.\d+(?:\.\d+)?)-desktop-amd64\.iso"#))
            ], isBuiltIn: false))

        let drive = try store.registerDrive(at: volume)
        store.setKeepOldVersions(keepOldVersions, for: drive.id)
        guard let assignment = store.addAssignment(entryID: "ubuntu", channelID: "lts", to: drive.id)
        else { throw XCTSkip("assignment could not be created") }
        if let installed {
            var updated = store.drive(id: drive.id)!
            updated.assignments[0].installed = installed
            store.updateDrive(updated)
            try TestFiles.write(volume.appendingPathComponent(installed.fileName), size: installedSize)
        }

        let release = Release(version: .parse("24.04.4")!,
                              isoURL: URL(string: "https://example.test/ubuntu-24.04.4-desktop-amd64.iso"),
                              fileName: "ubuntu-24.04.4-desktop-amd64.iso",
                              sha256: sha256, sizeBytes: Int64(isoSize))
        store.setRelease(release, for: ReleaseKey(entryID: "ubuntu", channelID: "lts"))

        let cached = try TestFiles.write(cacheDir.appendingPathComponent("ubuntu-24.04.4-desktop-amd64.iso"),
                                          size: isoSize)
        let provider = FakeISOProvider(behaviour: behaviour ?? .file(cached))
        let writer = FakeDriveWriter(availableBytes: availableBytes)
        let engine = UpdateEngine(store: store, downloads: provider, drives: writer)
        store.updateEngine = engine
        let recorder = RecordingNotificationService()
        store.notifications = recorder

        return Fixture(store: store, engine: engine, provider: provider, writer: writer,
                       driveID: drive.id, assignmentID: assignment.id, release: release)
    }

    private func run(_ fixture: Fixture, keepReplacedAsPinned: Bool = false) async {
        let request = UpdateRequest(driveID: fixture.driveID, driveName: "VENTOY",
                                    assignmentID: fixture.assignmentID, entryID: "ubuntu",
                                    channelID: "lts", title: "Ubuntu Desktop — LTS",
                                    release: fixture.release,
                                    keepReplacedAsPinned: keepReplacedAsPinned)
        await fixture.engine.enqueue([request])
        await fixture.engine.drain()
    }

    // MARK: - Replacing a file that shares the new name (PRD F61)

    func testAnISOCanReplaceAFileOfTheSameNameOnAFullDrive() async throws {
        // The reported case: a Ventoy stick with 589 MB free holding an 8.47 GB
        // Windows ISO, asked to place the same media again under the same name.
        // The bytes it is about to reclaim are the very bytes it needs.
        let installed = InstalledISO(fileName: "ubuntu-24.04.4-desktop-amd64.iso",
                                     version: .parse("24.04.4"), placedByApp: true)
        let fixture = try await makeFixture(installed: installed,
                                            availableBytes: 200 * 1024,   // not enough on its own
                                            isoSize: 256 * 1024,
                                            installedSize: 256 * 1024)    // but this is coming back
        await run(fixture)

        let placed = volume.appendingPathComponent("ubuntu-24.04.4-desktop-amd64.iso")
        XCTAssertTrue(FileManager.default.fileExists(atPath: placed.path))
        XCTAssertEqual(TestFiles.size(placed), 256 * 1024)
        // It succeeded, so nothing complained about room.
        XCTAssertEqual(fixture.store.history.first?.outcome, .succeeded)
        XCTAssertFalse(fixture.store.history.contains { $0.message?.contains("does not have room") == true })
        // Nothing is reported as "replaced": the file kept its name.
        XCTAssertNil(fixture.store.history.first?.message.flatMap { $0.contains("replaced") ? $0 : nil })
        // And no half-written leftovers.
        let listing = try FileManager.default.contentsOfDirectory(atPath: volume.path)
        XCTAssertFalse(listing.contains { DownloadArtifact.isPartFileName($0) })
    }

    func testADriveThatIsGenuinelyTooSmallStillSaysSo() async throws {
        // The other half of the fix: reclaiming the replaced file must not turn
        // a real shortfall into a false pass.
        let installed = InstalledISO(fileName: "ubuntu-24.04.4-desktop-amd64.iso",
                                     version: .parse("24.04.4"), placedByApp: true)
        let fixture = try await makeFixture(installed: installed,
                                            availableBytes: 8 * 1024,
                                            isoSize: 512 * 1024,
                                            installedSize: 16 * 1024)
        await run(fixture)

        XCTAssertEqual(fixture.store.history.first?.outcome, .failed)
        XCTAssertTrue(fixture.store.history.first?.message?.contains("does not have room") == true,
                      fixture.store.history.first?.message ?? "no message")
        // The old file is left alone when the copy was never attempted.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: volume.appendingPathComponent(installed.fileName).path))
    }

    func testKeepingOldVersionsStillReservesRoomForBoth() async throws {
        // PRD F6: the user asked to keep what is there, so its bytes are not
        // Isotope's to spend — even when the incoming file shares its name.
        let installed = InstalledISO(fileName: "ubuntu-24.04.3-desktop-amd64.iso",
                                     version: .parse("24.04.3"), placedByApp: true)
        let fixture = try await makeFixture(installed: installed, keepOldVersions: true,
                                            availableBytes: 200 * 1024,
                                            isoSize: 256 * 1024,
                                            installedSize: 256 * 1024)
        await run(fixture)

        XCTAssertEqual(fixture.store.history.first?.outcome, .failed)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: volume.appendingPathComponent(installed.fileName).path))
    }

    // MARK: - Happy path

    func testHappyPathCopiesRenamesAndRecordsTheAssignment() async throws {
        let fixture = try await makeFixture()
        await run(fixture)

        let placed = volume.appendingPathComponent("ubuntu-24.04.4-desktop-amd64.iso")
        XCTAssertTrue(FileManager.default.fileExists(atPath: placed.path))
        XCTAssertEqual(TestFiles.size(placed), 256 * 1024)
        // No `.part` leftovers (PRD F25).
        let listing = try FileManager.default.contentsOfDirectory(atPath: volume.path)
        XCTAssertFalse(listing.contains { DownloadArtifact.isPartFileName($0) })

        let assignment = fixture.store.drive(id: fixture.driveID)!.assignments[0]
        XCTAssertEqual(assignment.installed?.fileName, "ubuntu-24.04.4-desktop-amd64.iso")
        XCTAssertEqual(assignment.installed?.version?.raw, "24.04.4")
        XCTAssertEqual(assignment.installed?.placedByApp, true)
        XCTAssertEqual(fixture.store.staleness(of: assignment), .upToDate)

        // PRD F23/F24: the in-flight flag is released and history is written.
        XCTAssertFalse(fixture.store.drivesWithOperationsInFlight.contains(fixture.driveID))
        XCTAssertEqual(fixture.store.history.first?.outcome, .succeeded)
        XCTAssertEqual(fixture.store.operations.first?.phase, .completed)
        // The cache hold is balanced so eviction can proceed.
        XCTAssertEqual(fixture.provider.endedKeys.count, 1)
        XCTAssertEqual(fixture.writer.accessBalance, 0)
    }

    func testReplacingAnOldISODeletesExactlyThatFile() async throws {
        let fixture = try await makeFixture(installed: InstalledISO(fileName: "ubuntu-24.04.1-desktop-amd64.iso",
                                                              version: .parse("24.04.1"),
                                                              placedByApp: true))
        // A file Isotope never placed must survive untouched (PRD F22).
        try TestFiles.write(volume.appendingPathComponent("someones-other.iso"), size: 1024)
        await run(fixture)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: volume.appendingPathComponent("ubuntu-24.04.1-desktop-amd64.iso").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: volume.appendingPathComponent("ubuntu-24.04.4-desktop-amd64.iso").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: volume.appendingPathComponent("someones-other.iso").path))
        XCTAssertEqual(fixture.store.history.first?.message?.contains("replaced ubuntu-24.04.1"), true)
    }

    func testKeepOldVersionsLeavesThePreviousISOInPlace() async throws {
        let fixture = try await makeFixture(installed: InstalledISO(fileName: "ubuntu-24.04.1-desktop-amd64.iso",
                                                              version: .parse("24.04.1"),
                                                              placedByApp: true),
                                       keepOldVersions: true)
        await run(fixture)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: volume.appendingPathComponent("ubuntu-24.04.1-desktop-amd64.iso").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: volume.appendingPathComponent("ubuntu-24.04.4-desktop-amd64.iso").path))
    }

    // MARK: - Keep the replaced ISO as a pinned copy (PRD F35)

    func testKeepingTheReplacedISOAsAPinnedCopyLeavesTheFileAndAddsAnAssignment() async throws {
        let installed = InstalledISO(fileName: "ubuntu-24.04.1-desktop-amd64.iso",
                                     version: .parse("24.04.1"), placedByApp: true)
        let fixture = try await makeFixture(installed: installed)
        await run(fixture, keepReplacedAsPinned: true)

        // Both ISOs are on the drive: the old one was not deleted.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: volume.appendingPathComponent("ubuntu-24.04.1-desktop-amd64.iso").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: volume.appendingPathComponent("ubuntu-24.04.4-desktop-amd64.iso").path))

        let assignments = fixture.store.drive(id: fixture.driveID)!.assignments
        XCTAssertEqual(assignments.count, 2)
        let tracker = try XCTUnwrap(assignments.first { $0.id == fixture.assignmentID })
        XCTAssertEqual(tracker.updatePolicy, .trackLatest)
        XCTAssertEqual(tracker.installed?.fileName, "ubuntu-24.04.4-desktop-amd64.iso")

        let pinned = try XCTUnwrap(assignments.first { $0.id != fixture.assignmentID })
        XCTAssertEqual(pinned.updatePolicy, .keepAsIs)
        XCTAssertEqual(pinned.entryID, "ubuntu")
        XCTAssertEqual(pinned.channelID, "lts")
        XCTAssertEqual(pinned.installed?.fileName, "ubuntu-24.04.1-desktop-amd64.iso")
        XCTAssertEqual(pinned.installed?.version?.raw, "24.04.1")
        // Provenance is carried over, not invented (PRD F7/F22).
        XCTAssertEqual(pinned.installed?.placedByApp, true)

        // PRD F36: the pinned copy is not stale and not part of "Update All".
        XCTAssertEqual(fixture.store.staleness(of: pinned), .pinned)
        XCTAssertTrue(fixture.store.staleAssignments(on: fixture.store.drive(id: fixture.driveID)!).isEmpty)
        XCTAssertNil(fixture.store.history.first?.message?.range(of: "replaced"))

        // And it survives a relaunch.
        let reloaded = AppStore(locations: StoreLocations(root: root.appendingPathComponent("state")),
                                catalogResourceURL: nil)
        await reloaded.loadAtLaunch()
        XCTAssertEqual(reloaded.drives.first?.assignments.map(\.updatePolicy),
                       [.trackLatest, .keepAsIs])
    }

    func testAPinnedCopyIsOnlyMadeWhenTheUserAsksForIt() async throws {
        let installed = InstalledISO(fileName: "ubuntu-24.04.1-desktop-amd64.iso",
                                     version: .parse("24.04.1"), placedByApp: true)
        let fixture = try await makeFixture(installed: installed)
        await run(fixture)

        XCTAssertEqual(fixture.store.drive(id: fixture.driveID)!.assignments.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: volume.appendingPathComponent("ubuntu-24.04.1-desktop-amd64.iso").path))
    }

    func testPlanOffersTheKeepAsPinnedCopyCheckboxOnlyWhenAFileWouldBeDeleted() async throws {
        let installed = InstalledISO(fileName: "ubuntu-24.04.1-desktop-amd64.iso",
                                     version: .parse("24.04.1"), placedByApp: true)
        let fixture = try await makeFixture(installed: installed)
        let item = try XCTUnwrap(fixture.store.updatePlan(driveID: fixture.driveID,
                                                          assignmentIDs: [fixture.assignmentID]).items.first)
        XCTAssertTrue(item.canKeepReplacedAsPinned)
        XCTAssertEqual(item.installedFileName, "ubuntu-24.04.1-desktop-amd64.iso")
    }

    func testTheKeepAsPinnedCopyCheckboxIsHiddenWhenNothingIsInstalled() async throws {
        // Nothing installed → nothing to keep.
        let fresh = try await makeFixture()
        let item = try XCTUnwrap(fresh.store.updatePlan(driveID: fresh.driveID,
                                                        assignmentIDs: [fresh.assignmentID]).items.first)
        XCTAssertNil(item.installedFileName)
        XCTAssertFalse(item.canKeepReplacedAsPinned)
    }

    func testTheKeepAsPinnedCopyCheckboxIsHiddenWhenTheDriveKeepsOldVersions() async throws {
        // PRD F6 already retains the file, so the F35 offer would be redundant.
        let installed = InstalledISO(fileName: "ubuntu-24.04.1-desktop-amd64.iso",
                                     version: .parse("24.04.1"), placedByApp: true)
        let keeping = try await makeFixture(installed: installed, keepOldVersions: true)
        let item = try XCTUnwrap(keeping.store.updatePlan(driveID: keeping.driveID,
                                                          assignmentIDs: [keeping.assignmentID]).items.first)
        XCTAssertTrue(item.driveKeepsOldVersions)
        XCTAssertFalse(item.canKeepReplacedAsPinned)
    }

    func testAPinnedAssignmentIsNeverPlanned() async throws {
        let fixture = try await makeFixture()
        XCTAssertTrue(fixture.store.setUpdatePolicy(.keepAsIs, forAssignment: fixture.assignmentID,
                                                    on: fixture.driveID))
        XCTAssertTrue(fixture.store.updatePlan(driveID: fixture.driveID,
                                               assignmentIDs: [fixture.assignmentID]).isEmpty)
        XCTAssertTrue(fixture.store.updatePlanForAllStale(driveID: fixture.driveID).isEmpty)
    }

    // MARK: - Failures (PRD F25)

    func testChecksumMismatchFailsWithTheActionableMessageAndPlacesNothing() async throws {
        let fixture = try await makeFixture(provider: .failure(
            DownloadError.checksumMismatch(fileName: "ubuntu-24.04.4-desktop-amd64.iso")))
        await run(fixture)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: volume.path), [])
        let message = fixture.store.operations.first?.errorMessage ?? ""
        XCTAssertTrue(message.contains("Checksum mismatch"), message)
        XCTAssertTrue(message.contains("discarded"), message)
        XCTAssertEqual(fixture.store.history.first?.outcome, .failed)
        XCTAssertNil(fixture.store.drive(id: fixture.driveID)!.assignments[0].installed)
        XCTAssertFalse(fixture.store.drivesWithOperationsInFlight.contains(fixture.driveID))
    }

    func testInsufficientSpaceReportsTheExactShortfall() async throws {
        // 10 MB ISO, 1 MB free, nothing reclaimable → 9 MB + margin short.
        let isoSize = 10 * 1024 * 1024
        let fixture = try await makeFixture(availableBytes: 1024 * 1024, isoSize: isoSize)
        await run(fixture)

        let expected = SpacePlan(requiredBytes: Int64(isoSize), availableBytes: 1024 * 1024)
        let message = fixture.store.operations.first?.errorMessage ?? ""
        XCTAssertTrue(message.contains("short"), message)
        XCTAssertTrue(message.contains(ByteCountFormatter.string(fromByteCount: expected.shortfallBytes,
                                                                  countStyle: .file)), message)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: volume.path), [])
    }

    func testReclaimableOldISOLetsATightUpdateThrough() async throws {
        // 10 MB free is not enough for a 12 MB ISO, but the 8 MB file it
        // replaces is (PRD F18) — the engine deletes it first and proceeds.
        let installed = InstalledISO(fileName: "ubuntu-24.04.1-desktop-amd64.iso",
                                     version: .parse("24.04.1"), placedByApp: true)
        let fixture = try await makeFixture(installed: installed, availableBytes: 10 * 1024 * 1024,
                                            isoSize: 12 * 1024 * 1024)
        try TestFiles.write(volume.appendingPathComponent(installed.fileName), size: 8 * 1024 * 1024)
        await run(fixture)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: volume.appendingPathComponent("ubuntu-24.04.4-desktop-amd64.iso").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: volume.appendingPathComponent(installed.fileName).path))
    }

    func testReadOnlyVolumeIsRefusedAtPreFlight() async throws {
        let fixture = try await makeFixture()
        fixture.writer.isReadOnly = true
        await run(fixture)

        let message = fixture.store.operations.first?.errorMessage ?? ""
        XCTAssertTrue(message.contains("read-only"), message)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: volume.path), [])
        // Security scope is released even on the failure path.
        XCTAssertEqual(fixture.writer.accessBalance, 0)
    }

    func testDriveVanishingMidCopyFailsCleanlyAndLeavesNoUsableFile() async throws {
        // 8 MB copied 4 KB at a time gives the "unplug" plenty of chances to land.
        let fixture = try await makeFixture(isoSize: 8 * 1024 * 1024)
        await fixture.engine.setCopyChunkSize(4096)
        let volumePath = volume.path
        fixture.provider.beforeReturn = {
            // Pull the stick out as soon as the copy starts writing.
            Task.detached {
                let part = URL(fileURLWithPath: volumePath)
                    .appendingPathComponent(".ubuntu-24.04.4-desktop-amd64.iso.part")
                for _ in 0..<2000 {
                    if FileManager.default.fileExists(atPath: part.path) {
                        try? FileManager.default.removeItem(atPath: volumePath)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 200_000)
                }
            }
        }
        await run(fixture)

        let message = fixture.store.operations.first?.errorMessage ?? ""
        XCTAssertTrue(message.contains("disconnected"), message)
        // Whatever survived, it is never a finished-looking ISO.
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: volume.path)) ?? []
        XCTAssertFalse(listing.contains("ubuntu-24.04.4-desktop-amd64.iso"))
        XCTAssertNil(fixture.store.drive(id: fixture.driveID)!.assignments[0].installed)
        XCTAssertFalse(fixture.store.drivesWithOperationsInFlight.contains(fixture.driveID))
    }

    func testUnresolvableBookmarkIsActionable() async throws {
        let fixture = try await makeFixture()
        fixture.writer.resolveError = CocoaError(.fileNoSuchFile)
        await run(fixture)

        let message = fixture.store.operations.first?.errorMessage ?? ""
        XCTAssertTrue(message.contains("permission"), message)
        XCTAssertTrue(message.contains("register it again"), message)
    }

    func testStaleBookmarkIsRefreshedAndPersisted() async throws {
        let fixture = try await makeFixture()
        fixture.writer.refreshedBookmark = Data("refreshed:\(volume.path)".utf8)
        await run(fixture)

        XCTAssertEqual(fixture.store.drive(id: fixture.driveID)?.bookmark,
                       Data("refreshed:\(volume.path)".utf8))
    }

    // MARK: - Batching (PRD F17 "Update all")

    func testOperationsOnOneDriveRunSequentially() async throws {
        let fixture = try await makeFixture()
        // A second assignment on the same drive.
        fixture.store.addCustomEntry(CatalogEntry(
            id: "debian", name: "Debian", kind: .linux, channels: [
                Channel(id: "netinst", name: "netinst",
                        provider: .checksumFile(url: URL(string: "https://example.test/SHA256SUMS")!,
                                                filePattern: #"debian-(\d+\.\d+\.\d+)-amd64-netinst\.iso"#))
            ], isBuiltIn: false))
        let second = fixture.store.addAssignment(entryID: "debian", channelID: "netinst",
                                                  to: fixture.driveID)!
        let debianRelease = Release(version: .parse("12.7.0")!,
                                    isoURL: URL(string: "https://example.test/debian-12.7.0-amd64-netinst.iso"),
                                    fileName: "debian-12.7.0-amd64-netinst.iso",
                                    sha256: "def456", sizeBytes: 256 * 1024)
        fixture.store.setRelease(debianRelease, for: ReleaseKey(entryID: "debian", channelID: "netinst"))

        let plan = fixture.store.updatePlanForAllStale(driveID: fixture.driveID)
        XCTAssertEqual(plan.items.count, 2)
        let requests = plan.automatableItems.map {
            UpdateRequest(driveID: $0.driveID, driveName: $0.driveName, assignmentID: $0.id,
                          entryID: $0.entryID, channelID: $0.channelID, title: $0.title,
                          release: $0.release)
        }
        await fixture.engine.enqueue(requests)
        await fixture.engine.drain()

        // The fake provider hands both operations the same file; what matters is
        // that both completed and neither trampled the other's `.part`.
        XCTAssertEqual(fixture.store.operations.filter { $0.phase == .completed }.count, 2)
        XCTAssertNotNil(fixture.store.drive(id: fixture.driveID)!.assignments
            .first { $0.id == second.id }?.installed)
        let listing = try FileManager.default.contentsOfDirectory(atPath: volume.path)
        XCTAssertFalse(listing.contains { DownloadArtifact.isPartFileName($0) })
    }

    // MARK: - Cancel from the Activity view

    /// A second assignment on the fixture's drive, so two operations queue on it.
    private func addDebian(to fixture: Fixture) -> UpdateRequest {
        fixture.store.addCustomEntry(CatalogEntry(
            id: "debian", name: "Debian", kind: .linux, channels: [
                Channel(id: "netinst", name: "netinst",
                        provider: .checksumFile(url: URL(string: "https://example.test/SHA256SUMS")!,
                                                filePattern: #"debian-(\d+\.\d+\.\d+)-amd64-netinst\.iso"#))
            ], isBuiltIn: false))
        let assignment = fixture.store.addAssignment(entryID: "debian", channelID: "netinst",
                                                      to: fixture.driveID)!
        let release = Release(version: .parse("12.7.0")!,
                              isoURL: URL(string: "https://example.test/debian-12.7.0-amd64-netinst.iso"),
                              fileName: "debian-12.7.0-amd64-netinst.iso",
                              sha256: "def456", sizeBytes: 256 * 1024)
        return UpdateRequest(driveID: fixture.driveID, driveName: "VENTOY",
                             assignmentID: assignment.id, entryID: "debian", channelID: "netinst",
                             title: "Debian — netinst", release: release)
    }

    private func ubuntuRequest(_ fixture: Fixture) -> UpdateRequest {
        UpdateRequest(driveID: fixture.driveID, driveName: "VENTOY",
                      assignmentID: fixture.assignmentID, entryID: "ubuntu", channelID: "lts",
                      title: "Ubuntu Desktop — LTS", release: fixture.release)
    }

    private func gate(_ fixture: Fixture) throws -> (UpdateEngine, GatedISOProvider) {
        let file = try TestFiles.write(cacheDir.appendingPathComponent("gated.iso"), size: 256 * 1024)
        let gated = GatedISOProvider(file: file)
        let engine = UpdateEngine(store: fixture.store, downloads: gated, drives: fixture.writer)
        fixture.store.updateEngine = engine
        return (engine, gated)
    }

    func testCancellingADownloadStopsItAndSaysSoAtOnce() async throws {
        let fixture = try await makeFixture()
        let (engine, gated) = try gate(fixture)
        let request = ubuntuRequest(fixture)
        await engine.enqueue([request])
        await waitUntil { gated.started.count == 1 }

        fixture.store.cancelOperation(id: request.id)
        // The row changes before the engine has done anything.
        XCTAssertEqual(fixture.store.operations.first?.isCancelling, true)

        await engine.drain()
        XCTAssertEqual(fixture.store.operations.first?.phase, .cancelled)
        XCTAssertEqual(gated.cancelledKeys, [gated.started[0]])
        XCTAssertNil(fixture.store.drive(id: fixture.driveID)!.assignments[0].installed)
    }

    /// The reported bug's other half: an update waiting behind another one on
    /// the same drive ignored Cancel until its turn came.
    func testCancellingAQueuedUpdateEndsItWithoutWaitingForItsTurn() async throws {
        let fixture = try await makeFixture()
        let (engine, gated) = try gate(fixture)
        let first = ubuntuRequest(fixture)
        let second = addDebian(to: fixture)
        await engine.enqueue([first, second])
        await waitUntil { gated.started.count == 1 }

        fixture.store.cancelOperation(id: second.id)
        await waitUntil { fixture.store.operations.first { $0.id == second.id }?.phase == .cancelled }
        // The first is still downloading, untouched.
        XCTAssertEqual(fixture.store.operations.first { $0.id == first.id }?.isActive, true)

        gated.release()
        await engine.drain()
        XCTAssertEqual(fixture.store.operations.first { $0.id == first.id }?.phase, .completed)
        XCTAssertEqual(fixture.store.operations.first { $0.id == second.id }?.phase, .cancelled)
        // The cancelled one never started a download.
        XCTAssertEqual(gated.started.count, 1)
        XCTAssertEqual(fixture.store.history.filter { $0.outcome == .cancelled }.count, 1)
    }

    // MARK: - Plans (PRD F17/F21)

    func testPlanLabelsUnverifiedSourcesAndSkipsManualOnes() async throws {
        let fixture = try await makeFixture(sha256: nil)
        let plan = fixture.store.updatePlanForAllStale(driveID: fixture.driveID)
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertFalse(plan.items[0].isVerifiable)
        XCTAssertTrue(plan.hasUnverified)

        // A windowsManual entry is in the plan but not automatable (PRD §5.4).
        fixture.store.addCustomEntry(CatalogEntry(
            id: "windows-11", name: "Windows 11", kind: .windows, channels: [
                Channel(id: "default", name: "Current",
                        provider: .windowsManual(infoURL: URL(string: "https://example.test/info")!,
                                                 downloadPage: URL(string: "https://example.test/dl")!))
            ], isBuiltIn: false))
        let windows = fixture.store.addAssignment(entryID: "windows-11", channelID: "default",
                                                  to: fixture.driveID)!
        fixture.store.setRelease(Release(version: .parse("26100.1742")!, isoURL: nil, fileName: ""),
                                 for: ReleaseKey(entryID: "windows-11", channelID: "default"))

        let updated = fixture.store.updatePlanForAllStale(driveID: fixture.driveID)
        XCTAssertEqual(updated.items.count, 2)
        XCTAssertEqual(updated.manualItems.map(\.id), [windows.id])
        XCTAssertEqual(updated.automatableItems.count, 1)
    }

    // MARK: - Orphan cleanup (DESIGN §6)

    func testPartFileCleanupRemovesOnlyPartLeftovers() throws {
        try TestFiles.write(volume.appendingPathComponent(".ubuntu-24.04.4-desktop-amd64.iso.part"), size: 16)
        try TestFiles.write(volume.appendingPathComponent("keep-me.iso"), size: 16)
        try TestFiles.write(volume.appendingPathComponent(".DS_Store"), size: 16)

        let removed = PartFileCleanup.run(volume: volume, isoFolder: "")
        XCTAssertEqual(removed, [".ubuntu-24.04.4-desktop-amd64.iso.part"])
        let listing = try FileManager.default.contentsOfDirectory(atPath: volume.path).sorted()
        XCTAssertEqual(listing, [".DS_Store", "keep-me.iso"])
    }
}
