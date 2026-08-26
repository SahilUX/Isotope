import IsotopeCore
import XCTest
@testable import Isotope

/// PRD F63/F64: what a transfer says about itself, and what happens to a
/// hand-downloaded ISO once it is on the drive.
@MainActor
final class ManualSourceCleanupTests: XCTestCase {
    private var root: URL!
    private var volume: URL!
    private var downloads: URL!
    private var defaultsName: String!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeManualCleanup-\(UUID().uuidString)")
        volume = root.appendingPathComponent("VENTOY", isDirectory: true)
        downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defaultsName = "IsotopeManualCleanup-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Where the download goes afterwards (F64)

    func testTrashingTheSourceIsOnByDefault() {
        XCTAssertTrue(AppSettings(defaults: UserDefaults(suiteName: defaultsName)!)
            .trashManualSourceAfterPlacement)
    }

    func testAPlacedDownloadIsMovedToTheTrash() throws {
        let source = downloads.appendingPathComponent("Win11_25H2_English_x64_v2.iso")
        try TestFiles.write(source, size: 4096)

        XCTAssertTrue(UpdateEngine.trashSource(source, volume: volume))
        // Gone from Downloads...
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        // ...and recoverable, which is the whole reason it is the Trash and not
        // an unlink: it is the user's file, not Isotope's.
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: false)
        let recovered = trash.appendingPathComponent(source.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.path))
        try? FileManager.default.removeItem(at: recovered)
    }

    func testAFileOnTheDriveItselfIsNeverTrashed() throws {
        // "Choose File…" can point at an ISO already on the stick. Trashing that
        // would delete the very file just placed.
        let onDrive = volume.appendingPathComponent("Win11_25H2_English_x64_v2.iso")
        try TestFiles.write(onDrive, size: 4096)

        XCTAssertFalse(UpdateEngine.trashSource(onDrive, volume: volume))
        XCTAssertTrue(FileManager.default.fileExists(atPath: onDrive.path))
    }

    func testAFileInASubfolderOfTheDriveIsAlsoLeftAlone() throws {
        let folder = volume.appendingPathComponent("ISOs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let onDrive = folder.appendingPathComponent("Win11_25H2_English_x64_v2.iso")
        try TestFiles.write(onDrive, size: 4096)

        XCTAssertFalse(UpdateEngine.trashSource(onDrive, volume: volume))
        XCTAssertTrue(FileManager.default.fileExists(atPath: onDrive.path))
    }

    func testAFileThatCannotBeTrashedIsNotAFailedUpdate() {
        // Some volumes have no Trash; a missing file is the same shape of "no".
        let absent = downloads.appendingPathComponent("never-existed.iso")
        XCTAssertFalse(UpdateEngine.trashSource(absent, volume: volume))
    }

    // MARK: - Speed and time remaining (F63)

    func testARateReadsAsBytesPerSecond() {
        XCTAssertEqual(TransferSummary.rate(12_300_000), "12.3 MB/s")
        // Nothing to show before the estimator has a reading, rather than
        // "0 bytes/s" flickering at the start of every copy.
        XCTAssertNil(TransferSummary.rate(nil))
        XCTAssertNil(TransferSummary.rate(0))
        XCTAssertNil(TransferSummary.rate(.infinity))
    }

    func testTimeRemainingIsOnlyPromisedWhenItIsKnown() throws {
        let text = try XCTUnwrap(TransferSummary.remaining(245))
        XCTAssertTrue(text.hasSuffix("left"), text)
        XCTAssertNil(TransferSummary.remaining(nil))
        XCTAssertNil(TransferSummary.remaining(0))
        XCTAssertNil(TransferSummary.remaining(.infinity))
    }

    func testTheRowShowsWhicheverHalfItHas() throws {
        XCTAssertEqual(TransferSummary.rateAndRemaining(bytesPerSecond: 12_300_000, eta: nil),
                       "12.3 MB/s")
        let both = try XCTUnwrap(TransferSummary.rateAndRemaining(bytesPerSecond: 12_300_000, eta: 245))
        XCTAssertTrue(both.hasPrefix("12.3 MB/s · "), both)
        // And nothing at all rather than an empty separator.
        XCTAssertNil(TransferSummary.rateAndRemaining(bytesPerSecond: nil, eta: nil))
    }

    func testByteSummaryFallsBackWhenTheTotalIsUnknown() {
        XCTAssertEqual(TransferSummary.bytes(completed: 1_200_000_000, total: 8_470_000_000),
                       "1.2 GB of 8.47 GB")
        XCTAssertEqual(TransferSummary.bytes(completed: 1_200_000_000, total: nil), "1.2 GB")
        XCTAssertEqual(TransferSummary.bytes(completed: 1_200_000_000, total: 0), "1.2 GB")
    }
}
