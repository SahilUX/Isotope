import XCTest
@testable import IsotopeCore

final class InterruptedDownloadTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IsotopeCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(startedFrom: URL?) -> InterruptedDownload {
        InterruptedDownload(id: "abc", sourceURL: URL(string: "https://origin.test/a.iso")!,
                            fileName: "a.iso", bytesDownloaded: 10,
                            interruptedAt: Date(timeIntervalSince1970: 1_700_000_000),
                            wasPaused: true, startedFromURL: startedFrom)
    }

    func testStartedFromURLRoundTrips() throws {
        let original = record(startedFrom: URL(string: "https://fast.test/pub/a.iso")!)
        let url = directory.appendingPathComponent("resume.json")
        try JSONStore.save([original], to: url)
        XCTAssertEqual(try JSONStore.load([InterruptedDownload].self, from: url), [original])
    }

    func testManifestWrittenBeforeTheFieldExistedStillLoads() throws {
        let url = directory.appendingPathComponent("resume.json")
        try JSONStore.save([record(startedFrom: URL(string: "https://fast.test/pub/a.iso")!)], to: url)
        // Strip the key to get what 0.2.14 and earlier wrote.
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url))
                                    as? [[String: Any]])
        objects[0].removeValue(forKey: "startedFromURL")
        XCTAssertNil(objects[0]["startedFromURL"])
        try JSONSerialization.data(withJSONObject: objects).write(to: url)

        let loaded = try XCTUnwrap(JSONStore.load([InterruptedDownload].self, from: url))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertNil(loaded[0].startedFromURL)
        XCTAssertEqual(loaded[0].id, "abc")
    }
}
