import XCTest
@testable import IsotopeCore

/// Naming rules the pipeline depends on: unwrapping Memtest86+'s `.iso.zip`,
/// the `.part` convention from PRD F25, and stable cache keys.
final class DownloadArtifactTests: XCTestCase {
    // MARK: - Archives

    func testDetectsZipArchivesCaseInsensitively() {
        XCTAssertTrue(DownloadArtifact.isZipArchive("mt86plus_7.20_x86_64.iso.zip"))
        XCTAssertTrue(DownloadArtifact.isZipArchive("Thing.ZIP"))
        XCTAssertFalse(DownloadArtifact.isZipArchive("ubuntu-24.04.4-desktop-amd64.iso"))
        XCTAssertFalse(DownloadArtifact.isZipArchive("zip"))
    }

    func testUnwrapsTheISONameFromAnArchiveName() {
        XCTAssertEqual(DownloadArtifact.isoName(fromArchive: "mt86plus_7.20_x86_64.iso.zip"),
                       "mt86plus_7.20_x86_64.iso")
        // An archive that does not spell out ".iso" still yields an ISO name.
        XCTAssertEqual(DownloadArtifact.isoName(fromArchive: "memtest.zip"), "memtest.iso")
        XCTAssertEqual(DownloadArtifact.isoName(fromArchive: "Memtest.ISO.Zip"), "Memtest.ISO")
        // Non-archives pass through untouched.
        XCTAssertEqual(DownloadArtifact.isoName(fromArchive: "debian-12.7.0-amd64-netinst.iso"),
                       "debian-12.7.0-amd64-netinst.iso")
    }

    func testPlacedFileNameUnwrapsArchivesAndFallsBackToTheURL() {
        let zipped = Release(version: .parse("7.20")!,
                             isoURL: URL(string: "https://www.memtest.org/download/v7.20/mt86plus_7.20_x86_64.iso.zip"),
                             fileName: "mt86plus_7.20_x86_64.iso.zip")
        XCTAssertEqual(DownloadArtifact.placedFileName(for: zipped), "mt86plus_7.20_x86_64.iso")

        let noName = Release(version: .parse("1.0")!,
                             isoURL: URL(string: "https://host/path/thing.iso"),
                             fileName: "")
        XCTAssertEqual(DownloadArtifact.placedFileName(for: noName), "thing.iso")

        // Windows 11's cached release has neither (PRD §5.4).
        let windows = Release(version: .parse("26100.1234")!, isoURL: nil, fileName: "")
        XCTAssertNil(DownloadArtifact.placedFileName(for: windows))
    }

    // MARK: - .part files (PRD F25, DESIGN §6)

    func testPartFileNamesRoundTripAndStayHidden() {
        let part = DownloadArtifact.partFileName(for: "ubuntu-24.04.4-desktop-amd64.iso")
        XCTAssertEqual(part, ".ubuntu-24.04.4-desktop-amd64.iso.part")
        // Hidden, so a scan never mistakes a half-copy for an installed ISO.
        XCTAssertFalse(DriveScan.isISOFileName(part))
        XCTAssertTrue(DownloadArtifact.isPartFileName(part))
        XCTAssertEqual(DownloadArtifact.finalName(ofPartFile: part), "ubuntu-24.04.4-desktop-amd64.iso")
    }

    func testUnrelatedDotFilesAreNotMistakenForPartFiles() {
        XCTAssertFalse(DownloadArtifact.isPartFileName(".DS_Store"))
        XCTAssertFalse(DownloadArtifact.isPartFileName("something.part"))
        XCTAssertNil(DownloadArtifact.finalName(ofPartFile: ".DS_Store"))
    }

    // MARK: - Cache keys

    func testChecksumIsTheCacheKeyWhenPublished() {
        let key = DownloadArtifact.cacheKey(sha256: "AbCdEf",
                                            sourceURL: URL(string: "https://mirror1/x.iso"),
                                            fileName: "x.iso")
        XCTAssertEqual(key, "sha256-abcdef")
        // Same ISO, different mirror → same key, so it is downloaded once (F20).
        XCTAssertEqual(key, DownloadArtifact.cacheKey(sha256: "abcdef",
                                                      sourceURL: URL(string: "https://mirror2/x.iso"),
                                                      fileName: "x.iso"))
    }

    func testUnverifiedSourcesGetAStableURLDerivedKey() {
        let url = URL(string: "https://host/path/latest.iso?token=1")
        let a = DownloadArtifact.cacheKey(sha256: nil, sourceURL: url, fileName: "latest.iso")
        let b = DownloadArtifact.cacheKey(sha256: nil, sourceURL: url, fileName: "latest.iso")
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("url-"))
        XCTAssertNotEqual(a, DownloadArtifact.cacheKey(sha256: nil,
                                                       sourceURL: URL(string: "https://host/path/other.iso"),
                                                       fileName: "other.iso"))
    }

    func testCacheFileNameIsFilesystemSafeAndBounded() {
        let name = DownloadArtifact.cacheFileName(key: "sha256-ab",
                                                  fileName: "we ird/../name?.iso")
        XCTAssertTrue(name.hasPrefix("sha256-ab-"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains("?"))
        XCTAssertFalse(name.contains(" "))

        let long = DownloadArtifact.cacheFileName(key: "k", fileName: String(repeating: "a", count: 500))
        XCTAssertLessThanOrEqual(long.count, 130)
    }

    func testExtractedKeyIsDerivedFromItsArchive() {
        XCTAssertEqual(DownloadArtifact.extractedCacheKey(parentKey: "sha256-ab"), "sha256-ab-iso")
    }
}
