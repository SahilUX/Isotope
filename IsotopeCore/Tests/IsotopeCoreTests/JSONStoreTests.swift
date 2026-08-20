import XCTest
@testable import IsotopeCore

final class JSONStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSaveAndLoadRoundTrip() throws {
        let drive = ManagedDrive(
            volumeUUID: "8B0C1D2E-0000-4000-8000-000000000001",
            displayName: "SanDisk 64GB",
            bookmark: Data([0x01, 0x02, 0x03]),
            isoFolder: "ISOs",
            assignments: [
                Assignment(entryID: "ubuntu-desktop", channelID: "lts",
                           installed: InstalledISO(fileName: "ubuntu-24.04.1-desktop-amd64.iso",
                                                   version: VersionToken.parse("24.04.1"),
                                                   placedByApp: false,
                                                   updatedAt: Date(timeIntervalSince1970: 1_700_000_000)))
            ],
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_100),
            capacityBytes: 64_000_000_000
        )
        let url = directory.appendingPathComponent("drives.json")
        try JSONStore.save([drive], to: url)
        let loaded = try JSONStore.load([ManagedDrive].self, from: url)
        XCTAssertEqual(loaded, [drive])
    }

    func testLoadMissingFileReturnsNil() throws {
        let url = directory.appendingPathComponent("nope.json")
        XCTAssertNil(try JSONStore.load([ManagedDrive].self, from: url))
        XCTAssertEqual(JSONStore.load([ManagedDrive].self, from: url, default: []), [])
    }

    func testLoadCorruptFileThrows() throws {
        let url = directory.appendingPathComponent("bad.json")
        try Data("{ not json".utf8).write(to: url)
        XCTAssertThrowsError(try JSONStore.load([ManagedDrive].self, from: url))
        XCTAssertEqual(JSONStore.load([ManagedDrive].self, from: url, default: []), [])
    }

    func testSaveCreatesMissingDirectories() throws {
        let url = directory.appendingPathComponent("a/b/history.json")
        // ISO-8601 encoding is second-precision, so use a whole-second date.
        let events = [HistoryEvent(date: Date(timeIntervalSince1970: 1_700_000_000),
                                   driveName: "SanDisk", entryID: "ubuntu-desktop", channelID: "lts",
                                   fileName: "ubuntu-24.04.3-desktop-amd64.iso",
                                   version: VersionToken.parse("24.04.3"), outcome: .succeeded)]
        try JSONStore.save(events, to: url)
        XCTAssertEqual(try JSONStore.load([HistoryEvent].self, from: url), events)
    }

    func testReleaseCacheKeyedByReleaseKeyDescription() throws {
        let release = Release(version: VersionToken.parse("24.04.3")!,
                              isoURL: URL(string: "https://example.org/u.iso"),
                              fileName: "ubuntu-24.04.3-desktop-amd64.iso",
                              sha256: String(repeating: "a", count: 64),
                              sizeBytes: 6_000_000_000,
                              checkedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let key = ReleaseKey(entryID: "ubuntu-desktop", channelID: "lts")
        XCTAssertEqual(key.description, "ubuntu-desktop#lts")
        XCTAssertTrue(release.isVerifiable)

        let url = directory.appendingPathComponent("release-cache.json")
        try JSONStore.save([key.description: release], to: url)
        let loaded = try JSONStore.load([String: Release].self, from: url)
        XCTAssertEqual(loaded?[key.description], release)
    }

    func testStoreLocations() {
        let locations = StoreLocations(root: directory)
        XCTAssertEqual(locations.drives.lastPathComponent, "drives.json")
        XCTAssertEqual(locations.customSources.lastPathComponent, "custom-sources.json")
        XCTAssertEqual(locations.releaseCache.lastPathComponent, "release-cache.json")
        XCTAssertEqual(locations.history.lastPathComponent, "history.json")
    }
}
