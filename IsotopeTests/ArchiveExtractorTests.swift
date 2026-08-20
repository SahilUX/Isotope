import IsotopeCore
import XCTest
@testable import Isotope

/// Memtest86+ ships only `mt86plus_<version>_x86_64.iso.zip`, so the pipeline
/// has to unpack a zip. Foundation cannot, and this runs inside the sandboxed
/// app (the test host), which is exactly the environment the question "can we
/// spawn /usr/bin/ditto?" needs answering in.
final class ArchiveExtractorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeZipTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Builds the fixture with `ditto -c -k`, so a failure here also tells us
    /// process spawning is blocked, not just extraction.
    private func makeZip(containing name: String, size: Int) throws -> URL {
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try TestFiles.write(staging.appendingPathComponent(name), size: size)
        let zip = root.appendingPathComponent("fixture.iso.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, zip.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("ditto could not create the fixture archive (exit \(process.terminationStatus))")
        }
        return zip
    }

    func testDittoExtractsTheISOFromAZipInsideTheSandbox() throws {
        let zip = try makeZip(containing: "mt86plus_7.20_x86_64.iso", size: 32 * 1024)
        let destination = root.appendingPathComponent("out", isDirectory: true)

        let extracted = try DittoArchiveExtractor().extractISO(from: zip, into: destination)

        XCTAssertEqual(extracted.lastPathComponent, "mt86plus_7.20_x86_64.iso")
        XCTAssertEqual(TestFiles.size(extracted), 32 * 1024)
    }

    func testTheLargestISOWinsWhenAnArchiveHasSidecars() throws {
        let staging = root.appendingPathComponent("staging2", isDirectory: true)
        try TestFiles.write(staging.appendingPathComponent("tiny.iso"), size: 512)
        try TestFiles.write(staging.appendingPathComponent("nested/real.iso"), size: 8192)
        try TestFiles.write(staging.appendingPathComponent("readme.txt"), size: 32)

        let found = try DittoArchiveExtractor.firstISO(in: staging)
        XCTAssertEqual(found?.lastPathComponent, "real.iso")
    }

    func testAnArchiveWithoutAnISOIsAnActionableFailure() throws {
        let staging = root.appendingPathComponent("staging3", isDirectory: true)
        try TestFiles.write(staging.appendingPathComponent("notes.txt"), size: 32)
        let zip = root.appendingPathComponent("empty.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", staging.path, zip.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        XCTAssertThrowsError(try DittoArchiveExtractor()
            .extractISO(from: zip, into: root.appendingPathComponent("out3"))) { error in
            guard case ArchiveExtractionError.noISOInArchive = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("did not contain"))
        }
    }

    func testCorruptArchiveFailsWithoutCrashing() throws {
        let bogus = root.appendingPathComponent("bogus.zip")
        try Data("this is not a zip file".utf8).write(to: bogus)

        XCTAssertThrowsError(try DittoArchiveExtractor()
            .extractISO(from: bogus, into: root.appendingPathComponent("out4"))) { error in
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }
}
