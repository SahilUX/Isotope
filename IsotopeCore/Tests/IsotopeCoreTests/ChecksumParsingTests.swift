import XCTest
@testable import IsotopeCore

final class ChecksumParsingTests: XCTestCase {
    private let digest = "3f66b2e10b8bb2c573ed6cdd3a9b54fd0a8e7690634ab6b15c3c8f517992d1a1"

    func testLineFormatTable() {
        let cases: [(String, ChecksumParsing.Line?)] = [
            // GNU coreutils, text mode (two spaces).
            ("\(digest)  foo.iso", .init(hash: digest, fileName: "foo.iso")),
            // GNU coreutils, binary mode marker.
            ("\(digest) *foo.iso", .init(hash: digest, fileName: "foo.iso")),
            // Single space is still accepted in the wild.
            ("\(digest) foo.iso", .init(hash: digest, fileName: "foo.iso")),
            // Leading/trailing whitespace.
            ("   \(digest)  foo.iso   ", .init(hash: digest, fileName: "foo.iso")),
            // Filenames with spaces keep them.
            ("\(digest)  my image.iso", .init(hash: digest, fileName: "my image.iso")),
            // BSD tagged format.
            ("SHA256 (foo.iso) = \(digest)", .init(hash: digest, fileName: "foo.iso")),
            // Uppercase digests are normalised.
            ("\(digest.uppercased())  foo.iso", .init(hash: digest, fileName: "foo.iso")),
            // Non-SHA-256 digests are skipped, not misread.
            ("a4c701431cd41f24b6557622d922918e  foo.iso", nil),
            ("a75e2a042d4e94f7820aebc758b2e4a6b059f812  foo.iso", nil),
            // Section headers, comments, blank lines, hash without filename.
            ("### SHA256SUMS:", nil),
            ("# comment", nil),
            ("", nil),
            (digest, nil)
        ]
        for (input, expected) in cases {
            XCTAssertEqual(ChecksumParsing.lines(in: input).first, expected, "input: \(input)")
        }
    }

    func testMixedDigestFileYieldsOnlySHA256Lines() {
        let lines = ChecksumParsing.lines(in: Fixtures.text("gparted-CHECKSUMS.TXT"))
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.allSatisfy { ChecksumParsing.isSHA256($0.hash) })
        XCTAssertEqual(lines.first?.fileName, "gparted-live-1.8.1-3-amd64.iso")
    }

    func testBSDFixture() {
        let lines = ChecksumParsing.lines(in: Fixtures.text("bsd-checksums.txt"))
        XCTAssertEqual(lines.map(\.fileName), ["openbsd-7.6-amd64.iso", "openbsd-7.5-amd64.iso"])
    }

    func testSingleHashFileBothShapes() {
        XCTAssertEqual(ChecksumParsing.singleHash(in: digest + "\n"), digest)
        XCTAssertEqual(ChecksumParsing.singleHash(in: "\(digest)  foo.iso\n"), digest)
        XCTAssertNil(ChecksumParsing.singleHash(in: "not a hash\n"))
    }

    func testHrefExtraction() {
        let hrefs = HTMLParsing.hrefs(in: Fixtures.text("directory-listing.html"))
        XCTAssertTrue(hrefs.contains("SHA256SUMS"))                       // single quotes
        XCTAssertTrue(hrefs.contains("debian-13.6.0-amd64-netinst.iso"))
        XCTAssertTrue(hrefs.contains("debian-mac-13.6.0-amd64-netinst.iso")) // uppercase HREF
    }

    func testJSONPathMiniLanguage() throws {
        let data = Data(Fixtures.text("tails-latest.json").utf8)
        let root = try JSONSerialization.jsonObject(with: data)
        let install = JSONPath.value(root, at: "installations.0")
        XCTAssertEqual(JSONPath.string(install, at: "version"), "7.10.1")
        XCTAssertEqual(JSONPath.string(install, at: "installation-paths.[type=iso].target-files.0.url"),
                       "https://example.test/tails-amd64-7.10.1.iso")
        XCTAssertEqual(JSONPath.int64(install, at: "installation-paths.[type=img].target-files.0.size"),
                       1872756736)
        XCTAssertNil(JSONPath.value(root, at: "installations.9"))
        XCTAssertNil(JSONPath.value(root, at: "nope.nope"))
    }
}
