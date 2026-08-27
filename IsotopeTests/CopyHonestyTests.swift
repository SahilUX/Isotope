import IsotopeCore
import XCTest
@testable import Isotope

/// PRD F65: what the progress display says has to be what is happening.
///
/// It was not. macOS absorbs writes into RAM, so a copy to a USB stick reported
/// 81.5 MB/s and then 202.6 MB/s while `iostat` had the device doing 10–17 MB/s,
/// and the ETA shortened as the lie grew. The copy then sat at 100% for minutes
/// in the final flush, which looked like a hang.
@MainActor
final class CopyHonestyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeCopyHonesty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Writes reach the device, not the cache

    func testAnOpenFileCanBeTakenOutOfThePageCache() throws {
        let url = root.appendingPathComponent("scratch.bin")
        try Data(repeating: 0, count: 1024).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        XCTAssertTrue(ChunkedCopy.bypassCache(handle.fileDescriptor))
    }

    func testARefusedDescriptorIsNotAFailedCopy() {
        // Worth saying no to without throwing: it means the numbers go back to
        // being optimistic, not that the data is at risk.
        XCTAssertFalse(ChunkedCopy.bypassCache(-1))
        XCTAssertFalse(ChunkedCopy.bypassCache(9_999))
    }

    func testTheCopyStillProducesAnIdenticalFile() throws {
        // The cache bypass changes when bytes land, never which bytes.
        let source = try TestFiles.write(root.appendingPathComponent("source.iso"), size: 512 * 1024)
        let destination = root.appendingPathComponent("dest.iso")
        try ChunkedCopy.run(from: source, to: destination, chunkSize: 64 * 1024,
                            control: { .proceed }, progress: { _ in })

        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
    }

    // MARK: - The flush is part of the copy

    func testTheFlushIsAnnouncedBeforeItHappens() throws {
        let source = try TestFiles.write(root.appendingPathComponent("source.iso"), size: 256 * 1024)
        let destination = root.appendingPathComponent("dest.iso")

        let order = Recorder()
        try ChunkedCopy.run(from: source, to: destination, chunkSize: 64 * 1024,
                            control: { .proceed },
                            progress: { written in order.record("wrote \(written)") },
                            willSynchronize: { order.record("flush") })

        // Every byte is reported before the flush is announced, and the flush is
        // announced exactly once — the UI switches to "Finishing" there rather
        // than sitting at 100% under "Copying".
        let events = order.events
        XCTAssertEqual(events.filter { $0 == "flush" }.count, 1)
        XCTAssertEqual(events.last, "flush")
        XCTAssertEqual(events.first, "wrote 65536")
    }

    func testACopyWithoutTheFlushHookStillWorks() throws {
        // The callback is optional; the flash pipeline and the tests that
        // predate it pass nothing.
        let source = try TestFiles.write(root.appendingPathComponent("source.iso"), size: 128 * 1024)
        let destination = root.appendingPathComponent("dest.iso")
        try ChunkedCopy.run(from: source, to: destination, chunkSize: 64 * 1024,
                            control: { .proceed }, progress: { _ in })
        XCTAssertEqual(TestFiles.size(destination), 128 * 1024)
    }

    // MARK: - A full drive, named (PRD F68)

    func testAFullVolumeIsRecognisedHoweverItArrives() {
        // FileHandle reports it as Cocoa, a raw flush as POSIX, and Cocoa
        // sometimes only wraps the POSIX one.
        XCTAssertTrue(ChunkedCopy.isOutOfSpace(
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        XCTAssertTrue(ChunkedCopy.isOutOfSpace(
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        XCTAssertTrue(ChunkedCopy.isOutOfSpace(
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            ])))
        // And nothing else is mistaken for it — "the drive filled up" is a
        // claim, not a shrug.
        XCTAssertFalse(ChunkedCopy.isOutOfSpace(
            NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))))
        XCTAssertFalse(ChunkedCopy.isOutOfSpace(
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
    }

    func testAShortCopySaysTheDriveFilledUp() {
        // What the user actually saw was "The copied file is not the same size
        // as the source. It was discarded; try again." — after twelve minutes.
        let message = UpdateEngine.shortCopyMessage(copied: 8_410_000_000,
                                                    expected: 8_471_603_200,
                                                    driveName: "Ventoy")
        XCTAssertTrue(message.contains("8.41 GB"), message)
        XCTAssertTrue(message.contains("8.47 GB"), message)
        XCTAssertTrue(message.contains("filled up"), message)
        XCTAssertTrue(message.contains("Ventoy"), message)
    }

    func testACopyThatCameOutLongIsNotBlamedOnSpace() {
        let message = UpdateEngine.shortCopyMessage(copied: 9_000_000_000,
                                                    expected: 8_471_603_200,
                                                    driveName: "Ventoy")
        XCTAssertFalse(message.contains("filled up"), message)
    }

    // MARK: - Saying the same number twice

    func testTheRowSpellsOutThePercentage() {
        // Activity's bar is the width of the window and the drive row's is 70pt,
        // so the same 10% looked like two different amounts of progress.
        XCTAssertEqual(TransferSummary.phaseAndPercent("Copying to drive", fraction: 0.096),
                       "Copying to drive · 10%")
        XCTAssertEqual(TransferSummary.phaseAndPercent("Copying to drive", fraction: 1),
                       "Copying to drive · 100%")
        // Nothing to quote for an indeterminate transfer.
        XCTAssertEqual(TransferSummary.phaseAndPercent("Downloading", fraction: nil), "Downloading")
        XCTAssertEqual(TransferSummary.phaseAndPercent("Downloading", fraction: .nan), "Downloading")
    }
}

/// Records callback order across the copy's concurrency boundary.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    func record(_ event: String) {
        lock.lock()
        _events.append(event)
        lock.unlock()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }
}
