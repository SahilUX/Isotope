import IsotopeCore
import XCTest
@testable import Isotope

/// PRD F47: a downloaded ISO is deleted from the cache as soon as it is on the
/// drive. Covers the cache primitive, the setting, and the two cases where
/// deleting straight away would be wrong — a failed copy, and a second drive
/// still queued for the same file.
@MainActor
final class CacheDiscardTests: XCTestCase {
    private var root: URL!
    private var volume: URL!
    private var cacheDir: URL!
    private var locations: CacheLocations!
    private var defaultsName: String!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeDiscardTests-\(UUID().uuidString)")
        volume = root.appendingPathComponent("VENTOY", isDirectory: true)
        cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        locations = CacheLocations(root: cacheDir)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        try locations.ensureDirectoriesExist()
        defaultsName = "IsotopeDiscardTests-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }

    /// Tests get their own defaults suite: the setting is on by default, and
    /// reading that default must not depend on the developer's own preferences.
    private func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: defaultsName)!)
    }

    private func scratchFile(_ name: String, size: Int = 4096) throws -> URL {
        try TestFiles.write(root.appendingPathComponent("scratch").appendingPathComponent(name),
                            size: size)
    }

    // MARK: - The setting

    func testDeletingAfterPlacementIsOnByDefault() {
        XCTAssertTrue(settings().discardAfterPlacement)
    }

    func testTheSettingCanBeTurnedOffAndSticks() {
        let settings = settings()
        settings.discardAfterPlacement = false
        XCTAssertFalse(settings.discardAfterPlacement)
        XCTAssertFalse(AppSettings(defaults: UserDefaults(suiteName: defaultsName)!).discardAfterPlacement)
    }

    // MARK: - ISOCache.discardIfUnused

    func testDiscardDeletesTheFileAndReclaimsItsBytes() async throws {
        let cache = ISOCache(locations: locations)
        let artifact = try await cache.adopt(fileAt: try scratchFile("ubuntu.iso", size: 8192),
                                             key: "sha256-aa", fileName: "ubuntu.iso",
                                             sha256: "aa", sourceURL: URL(string: "https://a/u.iso"))
        let path = await cache.fileURL(artifact).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let freed = await cache.discardIfUnused(key: "sha256-aa")
        XCTAssertEqual(freed, 8192)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        // And it is gone from the index, so it is not offered as a cache hit.
        let hit = await cache.hit(sourceURL: URL(string: "https://a/u.iso"), sha256: "aa")
        XCTAssertNil(hit)
        let total = await cache.totalBytes
        XCTAssertEqual(total, 0)
    }

    func testDiscardRefusesWhileSomethingIsStillCopyingTheFile() async throws {
        let cache = ISOCache(locations: locations)
        let artifact = try await cache.adopt(fileAt: try scratchFile("ubuntu.iso", size: 8192),
                                             key: "sha256-aa", fileName: "ubuntu.iso",
                                             sha256: "aa", sourceURL: nil)
        await cache.retain(key: "sha256-aa")

        let freed = await cache.discardIfUnused(key: "sha256-aa")
        XCTAssertEqual(freed, 0)
        let path = await cache.fileURL(artifact).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        // Once the copy is done, the same call succeeds.
        await cache.release(key: "sha256-aa")
        let reclaimed = await cache.discardIfUnused(key: "sha256-aa")
        XCTAssertEqual(reclaimed, 8192)
    }

    func testDiscardingAnExtractedISOTakesItsArchiveWithIt() async throws {
        // Memtest86+ is cached as the .zip plus the .iso pulled out of it;
        // keeping the archive after the ISO is gone would be the same hoarding
        // in a smaller coat.
        let cache = ISOCache(locations: locations)
        let zip = try await cache.adopt(fileAt: try scratchFile("mt.iso.zip", size: 1024),
                                        key: "sha256-ee", fileName: "mt86plus.iso.zip",
                                        sha256: "ee", sourceURL: URL(string: "https://a/mt.zip"))
        let childKey = DownloadArtifact.extractedCacheKey(parentKey: zip.key)
        _ = try await cache.adopt(fileAt: try scratchFile("mt.iso", size: 4096),
                                  key: childKey, fileName: "mt86plus.iso",
                                  sha256: nil, sourceURL: nil, derivedFromKey: zip.key)

        let freed = await cache.discardIfUnused(key: childKey)
        XCTAssertEqual(freed, 4096 + 1024)
        let total = await cache.totalBytes
        XCTAssertEqual(total, 0)
    }

    func testDiscardingAnUnknownKeyIsANoOp() async {
        let cache = ISOCache(locations: locations)
        let freed = await cache.discardIfUnused(key: "sha256-nothing")
        XCTAssertEqual(freed, 0)
    }

    func testDownloadManagerDiscardsOnlyWhenAsked() async throws {
        let cache = ISOCache(locations: locations)
        _ = try await cache.adopt(fileAt: try scratchFile("ubuntu.iso", size: 4096),
                                  key: "sha256-dd", fileName: "ubuntu.iso",
                                  sha256: "dd", sourceURL: URL(string: "https://example.test/u.iso"))
        let manager = DownloadManager(cache: cache, locations: locations, hashing: CryptoKitHashing())
        let request = ISORequest(sourceURL: URL(string: "https://example.test/u.iso")!,
                                 fileName: "ubuntu.iso", sha256: "dd")
        var local = try await manager.ensureLocalISO(request) { _, _ in }
        var freed = await manager.endUse(cacheKey: local.cacheKey, discard: false)
        XCTAssertEqual(freed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.url.path))

        local = try await manager.ensureLocalISO(request) { _, _ in }
        freed = await manager.endUse(cacheKey: local.cacheKey, discard: true)
        XCTAssertEqual(freed, 4096)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.url.path))
    }

    // MARK: - Through the update pipeline

    private struct Fixture {
        var store: AppStore
        var engine: UpdateEngine
        var provider: FakeISOProvider
        var requests: [UpdateRequest]
    }

    /// `driveCount` sticks, each assigned the same ISO — the "Update All across
    /// two Ventoy drives" case.
    private func makeFixture(driveCount: Int = 1, discardAfterPlacement: Bool = true,
                             behaviour: FakeISOProvider.Behaviour? = nil) async throws -> Fixture {
        let settings = settings()
        settings.discardAfterPlacement = discardAfterPlacement
        let store = AppStore(locations: StoreLocations(root: root.appendingPathComponent("state")),
                             catalogResourceURL: nil, settings: settings)
        var volumes: [String: URL] = [:]
        for index in 0..<driveCount {
            let path = root.appendingPathComponent("VENTOY\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            volumes["UUID-\(index)"] = path
        }
        store.driveProbe = DriveProbe(
            info: { url in
                let uuid = volumes.first { $0.value == url }?.key ?? "UUID-X"
                return VolumeInfo(url: url, volumeUUID: uuid, name: url.lastPathComponent,
                                  capacityBytes: 64 << 30, availableBytes: 64 << 30,
                                  isReadOnly: false, isRemovable: true)
            },
            bookmark: { url in Data(url.path.utf8) },
            listISOs: { _, _ in [] })

        await store.loadAtLaunch()
        store.addCustomEntry(CatalogEntry(
            id: "ubuntu", name: "Ubuntu Desktop", kind: .linux,
            channels: [Channel(id: "lts", name: "LTS", provider: .checksumFile(
                url: URL(string: "https://example.test/SHA256SUMS")!,
                filePattern: #"ubuntu-(\d+\.\d+(?:\.\d+)?)-desktop-amd64\.iso"#))],
            isBuiltIn: false))

        let release = Release(version: .parse("24.04.4")!,
                              isoURL: URL(string: "https://example.test/ubuntu-24.04.4-desktop-amd64.iso"),
                              fileName: "ubuntu-24.04.4-desktop-amd64.iso",
                              sha256: "abc123", sizeBytes: 256 * 1024)
        store.setRelease(release, for: ReleaseKey(entryID: "ubuntu", channelID: "lts"))

        var requests: [UpdateRequest] = []
        for index in 0..<driveCount {
            let drive = try store.registerDrive(at: volumes["UUID-\(index)"]!)
            guard let assignment = store.addAssignment(entryID: "ubuntu", channelID: "lts", to: drive.id)
            else { throw XCTSkip("assignment could not be created") }
            requests.append(UpdateRequest(driveID: drive.id, driveName: "VENTOY\(index)",
                                          assignmentID: assignment.id, entryID: "ubuntu",
                                          channelID: "lts", title: "Ubuntu Desktop — LTS",
                                          release: release))
        }

        let cached = try TestFiles.write(cacheDir.appendingPathComponent("ubuntu-24.04.4-desktop-amd64.iso"),
                                         size: 256 * 1024)
        let provider = FakeISOProvider(behaviour: behaviour ?? .file(cached))
        let engine = UpdateEngine(store: store, downloads: provider, drives: FakeDriveWriter())
        store.updateEngine = engine
        store.notifications = RecordingNotificationService()
        return Fixture(store: store, engine: engine, provider: provider, requests: requests)
    }

    func testAPlacedISOIsDeletedFromTheCache() async throws {
        let fixture = try await makeFixture()
        await fixture.engine.enqueue(fixture.requests)
        await fixture.engine.drain()

        XCTAssertEqual(fixture.provider.discardedKeys.count, 1)
        XCTAssertEqual(fixture.provider.discardedKeys, fixture.provider.endedKeys)
        // And the reclaimed space is in the history line rather than silent.
        XCTAssertTrue(fixture.store.history.first?.message?.contains("freed") == true,
                      fixture.store.history.first?.message ?? "no history")
    }

    func testTurningTheSettingOffKeepsTheDownload() async throws {
        let fixture = try await makeFixture(discardAfterPlacement: false)
        await fixture.engine.enqueue(fixture.requests)
        await fixture.engine.drain()

        XCTAssertEqual(fixture.provider.endedKeys.count, 1)
        XCTAssertTrue(fixture.provider.discardedKeys.isEmpty)
        XCTAssertFalse(fixture.store.history.first?.message?.contains("freed") == true)
    }

    func testAnISOAnotherQueuedDriveStillNeedsIsKeptUntilTheLastOne() async throws {
        // Two sticks, one ISO: deleting after the first would force a second
        // download of the file we are about to copy again.
        let fixture = try await makeFixture(driveCount: 2)
        await fixture.engine.enqueue(fixture.requests)
        await fixture.engine.drain()

        XCTAssertEqual(fixture.provider.endedKeys.count, 2)
        XCTAssertEqual(fixture.provider.discardedKeys.count, 1)
    }

    func testAFailedCopyKeepsTheDownloadForTheRetry() async throws {
        let fixture = try await makeFixture()
        // A drive that vanished mid-operation: the copy fails after the ISO is
        // in hand, and re-downloading 4 GB to retry would be a poor apology.
        var request = fixture.requests[0]
        request.driveID = UUID()
        await fixture.engine.enqueue([request])
        await fixture.engine.drain()

        XCTAssertTrue(fixture.provider.discardedKeys.isEmpty)
    }
}
