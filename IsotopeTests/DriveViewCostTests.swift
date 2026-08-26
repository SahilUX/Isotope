import IsotopeCore
import XCTest
@testable import Isotope

/// PRD F62: what one redraw of a drive costs.
///
/// The app went unresponsive during a copy — spinning cursor, no input — while
/// the copy itself ran happily off the main actor. The main thread was busy
/// elsewhere: every progress tick invalidated the drive view, and every redraw
/// matched the drive's unclaimed files against all 106 catalog channels twice,
/// compiling a fresh regex for each. These tests hold that shut.
@MainActor
final class DriveViewCostTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeCostTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Detection is computed once per scan, not per read

    func testTheViewReadsADetectionItDoesNotRecompute() async throws {
        let volume = root.appendingPathComponent("VENTOY", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let store = AppStore(locations: StoreLocations(root: root.appendingPathComponent("state")),
                             catalogResourceURL: nil)
        store.driveProbe = DriveProbe(
            info: { url in VolumeInfo(url: url, volumeUUID: "UUID-A", name: "VENTOY",
                                      capacityBytes: 64 << 30, availableBytes: 32 << 30,
                                      isReadOnly: false, isRemovable: true) },
            bookmark: { url in Data(url.path.utf8) },
            listISOs: { _, _ in ["ubuntu-24.04.4-desktop-amd64.iso", "mystery.iso"] })
        await store.loadAtLaunch()
        store.addCustomEntry(CatalogEntry(
            id: "ubuntu", name: "Ubuntu Desktop", kind: .linux,
            channels: [Channel(id: "lts", name: "LTS", provider: .checksumFile(
                url: URL(string: "https://ubuntu.invalid/SHA256SUMS")!,
                filePattern: #"^ubuntu-(\d+\.\d+(?:\.\d+)?)-desktop-amd64\.iso$"#))],
            isBuiltIn: false))
        let drive = try store.registerDrive(at: volume)
        store.scanAndReconcile(driveID: drive.id)

        XCTAssertEqual(store.detectedISOs(on: try XCTUnwrap(store.drive(id: drive.id))).map(\.fileName),
                       ["ubuntu-24.04.4-desktop-amd64.iso"])
        XCTAssertEqual(store.unrecognizedISOFiles(on: try XCTUnwrap(store.drive(id: drive.id))),
                       ["mystery.iso"])

        // A new source recognises a file already on the drive, and the offers
        // follow without waiting for the next scan.
        store.addCustomEntry(CatalogEntry(
            id: "mystery", name: "Mystery OS", kind: .linux,
            channels: [Channel(id: "default", name: "Stable", provider: .checksumFile(
                url: URL(string: "https://mystery.invalid/SHA256SUMS")!,
                filePattern: #"^mystery\.iso$"#))],
            isBuiltIn: false))
        XCTAssertEqual(Set(store.detectedISOs(on: try XCTUnwrap(store.drive(id: drive.id))).map(\.fileName)),
                       ["ubuntu-24.04.4-desktop-amd64.iso", "mystery.iso"])
        XCTAssertTrue(store.unrecognizedISOFiles(on: try XCTUnwrap(store.drive(id: drive.id))).isEmpty)

        // And it is dropped with the drive.
        store.unregisterDrive(id: drive.id)
        XCTAssertNil(store.detectedISOsByDrive[drive.id])
    }

    // MARK: - Progress reports

    func testProgressIsThrottledButTheLastOneAlwaysLands() {
        let throttle = ProgressThrottle(interval: 60)
        let start = Date()
        XCTAssertTrue(throttle.shouldEmit(now: start))
        // Everything inside the window is dropped...
        XCTAssertFalse(throttle.shouldEmit(now: start.addingTimeInterval(1)))
        XCTAssertFalse(throttle.shouldEmit(now: start.addingTimeInterval(30)))
        // ...but the final report is never dropped, or the bar would stop short.
        XCTAssertTrue(throttle.shouldEmit(force: true, now: start.addingTimeInterval(31)))
        // ...and the window runs from the last one actually emitted.
        XCTAssertFalse(throttle.shouldEmit(now: start.addingTimeInterval(32)))
        XCTAssertTrue(throttle.shouldEmit(now: start.addingTimeInterval(120)))
    }

    func testTheDefaultRateIsWellUnderAChunkPerReport() {
        // A 4 MiB chunk on a quick stick arrives far more often than this.
        XCTAssertEqual(ProgressThrottle.defaultInterval, 0.1)
    }
}
