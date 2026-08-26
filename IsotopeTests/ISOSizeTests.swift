import IsotopeCore
import XCTest
@testable import Isotope

/// PRD F60: every ISO on a drive shows what it takes up. The sizes come from
/// the scan itself, so they can never describe a file the drive no longer has.
@MainActor
final class ISOSizeTests: XCTestCase {
    private var root: URL!
    private var volume: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeSizeTests-\(UUID().uuidString)")
        volume = root.appendingPathComponent("VENTOY", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// `nonisolated` so the injected probe closures can build one.
    private nonisolated static func volumeInfo(_ url: URL) -> VolumeInfo {
        VolumeInfo(url: url, volumeUUID: "UUID-A", name: "VENTOY",
                   capacityBytes: 64 << 30, availableBytes: 32 << 30,
                   isReadOnly: false, isRemovable: true)
    }

    private var ubuntuEntry: CatalogEntry {
        CatalogEntry(id: "ubuntu", name: "Ubuntu Desktop", kind: .linux,
                     channels: [Channel(id: "lts", name: "LTS", provider: .checksumFile(
                         url: URL(string: "https://ubuntu.invalid/SHA256SUMS")!,
                         filePattern: #"^ubuntu-(\d+\.\d+(?:\.\d+)?)-desktop-amd64\.iso$"#))],
                     isBuiltIn: false)
    }

    // MARK: - Reading sizes off a real folder

    func testSizesComeFromTheFolderItself() throws {
        try TestFiles.write(volume.appendingPathComponent("ubuntu-24.04.4-desktop-amd64.iso"), size: 4096)
        try TestFiles.write(volume.appendingPathComponent("Win11_25H2_English_x64_v2.iso"), size: 8192)
        // Not ISOs, and not measured.
        try TestFiles.write(volume.appendingPathComponent("readme.txt"), size: 10)
        try TestFiles.write(volume.appendingPathComponent(".hidden.iso"), size: 10)

        let sizes = try DriveAccess.isoSizes(inFolder: volume)
        XCTAssertEqual(sizes, ["ubuntu-24.04.4-desktop-amd64.iso": 4096,
                               "Win11_25H2_English_x64_v2.iso": 8192])
    }

    func testAFolderThatCannotBeReadYieldsNoSizesRatherThanFailing() {
        // A size is a nicety; a scan must never fail over one.
        XCTAssertTrue(DriveAccess.isoSizes(bookmark: Data("nonsense".utf8), isoFolder: "").isEmpty)
    }

    // MARK: - Through a scan

    func testAScanRecordsTheSizeOfEveryISOOnTheDrive() async throws {
        try TestFiles.write(volume.appendingPathComponent("ubuntu-24.04.4-desktop-amd64.iso"), size: 4096)
        try TestFiles.write(volume.appendingPathComponent("mystery.iso"), size: 2048)

        let store = AppStore(locations: StoreLocations(root: root.appendingPathComponent("state")),
                             catalogResourceURL: nil)
        let volumeURL = volume!
        store.driveProbe = DriveProbe(
            info: { url in Self.volumeInfo(url) },
            bookmark: { url in Data(url.path.utf8) },
            listISOs: { _, _ in ["ubuntu-24.04.4-desktop-amd64.iso", "mystery.iso"] },
            isoSizes: { _, _ in (try? DriveAccess.isoSizes(inFolder: volumeURL)) ?? [:] })
        await store.loadAtLaunch()
        store.addCustomEntry(ubuntuEntry)
        let drive = try store.registerDrive(at: volume)
        store.addAssignment(entryID: "ubuntu", channelID: "lts", to: drive.id)
        store.scanAndReconcile(driveID: drive.id)

        // The tracked ISO...
        XCTAssertEqual(store.isoSize(fileName: "ubuntu-24.04.4-desktop-amd64.iso", on: drive.id), 4096)
        // ...and the one nothing claims, which the row also lists.
        XCTAssertEqual(store.isoSize(fileName: "mystery.iso", on: drive.id), 2048)
        // Nothing invented for a file that is not there.
        XCTAssertNil(store.isoSize(fileName: "absent.iso", on: drive.id))
        XCTAssertNil(store.isoSize(fileName: nil, on: drive.id))
    }

    func testSizesFollowTheDriveAndAreDroppedWithIt() async throws {
        try TestFiles.write(volume.appendingPathComponent("ubuntu-24.04.4-desktop-amd64.iso"), size: 4096)
        let store = AppStore(locations: StoreLocations(root: root.appendingPathComponent("state")),
                             catalogResourceURL: nil)
        let volumeURL = volume!
        store.driveProbe = DriveProbe(
            info: { url in Self.volumeInfo(url) },
            bookmark: { url in Data(url.path.utf8) },
            listISOs: { _, _ in ["ubuntu-24.04.4-desktop-amd64.iso"] },
            isoSizes: { _, _ in (try? DriveAccess.isoSizes(inFolder: volumeURL)) ?? [:] })
        await store.loadAtLaunch()
        store.addCustomEntry(ubuntuEntry)
        let drive = try store.registerDrive(at: volume)
        store.scanAndReconcile(driveID: drive.id)
        XCTAssertFalse(store.isoSizes[drive.id]?.isEmpty ?? true)

        store.unregisterDrive(id: drive.id)
        XCTAssertNil(store.isoSizes[drive.id])
    }

    func testAProbeThatReportsNothingLeavesRowsWithoutASize() async throws {
        // The default when a drive is registered but never scanned, and when the
        // folder is unreadable: the row shows the version and no size at all.
        let store = AppStore(locations: StoreLocations(root: root.appendingPathComponent("state")),
                             catalogResourceURL: nil)
        store.driveProbe = DriveProbe(
            info: { url in Self.volumeInfo(url) },
            bookmark: { url in Data(url.path.utf8) },
            listISOs: { _, _ in ["ubuntu-24.04.4-desktop-amd64.iso"] },
            isoSizes: { _, _ in [:] })
        await store.loadAtLaunch()
        store.addCustomEntry(ubuntuEntry)
        let drive = try store.registerDrive(at: volume)
        store.scanAndReconcile(driveID: drive.id)
        XCTAssertNil(store.isoSize(fileName: "ubuntu-24.04.4-desktop-amd64.iso", on: drive.id))
    }
}
