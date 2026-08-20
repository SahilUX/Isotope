import IsotopeCore
import XCTest
@testable import Isotope

@MainActor
final class AppStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeAppTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(catalog: URL? = nil) -> AppStore {
        AppStore(locations: StoreLocations(root: root), catalogResourceURL: catalog)
    }

    func testLoadsBundledCatalogResource() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "catalog", withExtension: "json"),
                                "catalog.json must be bundled with the app")
        let store = makeStore(catalog: url)
        await store.loadAtLaunch()
        XCTAssertFalse(store.builtInEntries.isEmpty)
        XCTAssertTrue(store.builtInEntries.allSatisfy { $0.isBuiltIn && !$0.channels.isEmpty })
        XCTAssertNil(store.lastLoadError)
    }

    func testEmptyStateOnFirstRun() async {
        let store = makeStore()
        await store.loadAtLaunch()
        XCTAssertFalse(store.hasAnyDrives)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertTrue(store.releases.isEmpty)
    }

    func testDrivePersistenceRoundTrip() async throws {
        let store = makeStore()
        await store.loadAtLaunch()
        let drive = ManagedDrive(volumeUUID: "UUID-1", displayName: "SanDisk", bookmark: Data([0x01]))
        store.addDrive(drive)

        let reloaded = makeStore()
        await reloaded.loadAtLaunch()
        XCTAssertEqual(reloaded.drives.map(\.id), [drive.id])

        reloaded.removeDrive(id: drive.id)
        let afterRemoval = makeStore()
        await afterRemoval.loadAtLaunch()
        XCTAssertTrue(afterRemoval.drives.isEmpty)
    }

    func testStalenessUsesResolvedRelease() async {
        let store = makeStore()
        await store.loadAtLaunch()
        let assignment = Assignment(entryID: "ubuntu-desktop", channelID: "lts",
                                    installed: InstalledISO(fileName: "ubuntu-24.04.1-desktop-amd64.iso",
                                                            version: VersionToken.parse("24.04.1"),
                                                            placedByApp: false))
        let drive = ManagedDrive(volumeUUID: "UUID-2", displayName: "Ventoy", bookmark: Data(),
                                 assignments: [assignment])
        store.addDrive(drive)

        // No resolved release yet → nothing is reported stale.
        XCTAssertTrue(store.staleAssignments(on: drive).isEmpty)

        store.setRelease(Release(version: VersionToken.parse("24.04.3")!,
                                 fileName: "ubuntu-24.04.3-desktop-amd64.iso"),
                         for: assignment.releaseKey)
        XCTAssertEqual(store.staleAssignments(on: drive).map(\.id), [assignment.id])

        store.setRelease(Release(version: VersionToken.parse("24.04.1")!,
                                 fileName: "ubuntu-24.04.1-desktop-amd64.iso"),
                         for: assignment.releaseKey)
        XCTAssertTrue(store.staleAssignments(on: drive).isEmpty)
    }

    func testCryptoKitHashingMatchesKnownVector() throws {
        // SHA-256 of "abc".
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(CryptoKitHashing().sha256Hex(of: Data("abc".utf8)), expected)
    }
}
